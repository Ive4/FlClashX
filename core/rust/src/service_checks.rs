use crate::{core::Core, probe, profile, protocol};
use futures::{stream, StreamExt};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    net::IpAddr,
    sync::{Arc, OnceLock},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio_util::sync::CancellationToken;

const SERVICES: &[&str] = &[
    "google",
    "github",
    "youtube",
    "chatgpt",
    "claude",
    "gemini",
    "netflix",
    "disney-plus",
    "prime-video",
    "spotify",
    "tiktok",
    "discord",
    "bilibili",
];
const DISNEY_AUTH: &str =
    "Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84";

pub async fn invoke(core: &Core, method: &str, arguments: &Value) -> protocol::Result<Value> {
    protocol::object(arguments)?;
    if method == "outboundIp" {
        outbound_ip(core, arguments).await
    } else {
        services(core, arguments).await
    }
}

pub fn mentions_ip(body: &str) -> bool {
    body.split(|c: char| !(c.is_ascii_alphanumeric() || matches!(c, '.' | ':')))
        .filter_map(|token| token.parse::<IpAddr>().ok())
        .any(public_ip)
}

fn public_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => {
            let octets = ip.octets();
            !ip.is_private()
                && !ip.is_loopback()
                && !ip.is_unspecified()
                && !ip.is_link_local()
                && !ip.is_multicast()
                && !ip.is_broadcast()
                && !(octets[0] == 100 && (64..=127).contains(&octets[1]))
        }
        IpAddr::V6(ip) => {
            if let Some(mapped) = ip.to_ipv4_mapped() {
                public_ip(IpAddr::V4(mapped))
            } else {
                !ip.is_unique_local()
                    && !ip.is_loopback()
                    && !ip.is_unspecified()
                    && !ip.is_unicast_link_local()
                    && !ip.is_multicast()
            }
        }
    }
}

async fn outbound_ip(core: &Core, arguments: &Value) -> protocol::Result<Value> {
    let engine = core.active()?;
    let stamp = core.stamp();
    let urls = protocol::list(&arguments["urls"])?
        .iter()
        .map(protocol::string)
        .collect::<protocol::Result<Vec<_>>>()?;
    let timeout = probe::budget(arguments);
    let name = arguments["proxy-name"].as_str().unwrap_or("");
    let mut tasks = tokio::task::JoinSet::new();
    let mut next = 0;
    let mut all_hits = Vec::new();
    let mut ticker = tokio::time::interval(Duration::from_millis(800));
    let deadline = tokio::time::sleep(timeout);
    tokio::pin!(deadline);
    let mut result = loop {
        if tasks.is_empty() && next >= urls.len() {
            break json!({"url":"","body":"","delay":0,"chains":[],"error":"failed","hits":all_hits});
        }
        tokio::select! {
            _=&mut deadline=>break json!({"url":"","body":"","delay":0,"chains":[],"error":"timeout","hits":all_hits}),
            _=ticker.tick(),if next<urls.len()&&tasks.len()<3=>{
                let url=urls[next].to_owned();next+=1;let engine=Arc::clone(&engine);
                let params=core.probe_arguments(&json!({"url":url,"proxy-name":name,"timeout":timeout.as_millis()as u64,"max-body":4096}));
                tasks.spawn(async move{(url,probe::run(engine,&params).await)});
            }
            answer=tasks.join_next(),if !tasks.is_empty()=>{
                if let Some(Ok((url,Ok(mut answer))))=answer{
                    merge_hits(&mut all_hits,&answer["hits"]);
                    if answer["status-code"]==200&&answer["body"].as_str().is_some_and(mentions_ip){
                        answer["url"]=json!(url);answer["hits"]=json!(all_hits);
                        if let Some(node)=answer["chains"].as_array().and_then(|chains|chains.first()).and_then(Value::as_str).filter(|node|*node!=name).map(str::to_owned){
                            let mut hits=Vec::new();
                            for hit in answer["hits"].as_array().into_iter().flatten(){
                                if let Some(host)=hit["host"].as_str(){
                                    hits.push(json!({"host":host,"proxy":node,"exit":probe::exit(&engine,host,&node).await.unwrap_or_default()}));
                                }
                            }
                            answer["node-hits"]=json!(hits);
                        }
                        break answer;
                    }
                }
                if next<urls.len()&&tasks.len()<3{ticker.reset_immediately();}
            }
        }
    };
    tasks.abort_all();
    while tasks.join_next().await.is_some() {}
    profile::patch(&mut result, &stamp);
    Ok(result)
}

fn merge_hits(hits: &mut Vec<Value>, value: &Value) {
    for hit in value.as_array().into_iter().flatten() {
        if let Some(old) = hits
            .iter_mut()
            .find(|old| old["host"] == hit["host"] && old["proxy"] == hit["proxy"])
        {
            *old = hit.clone();
        } else {
            hits.push(hit.clone());
        }
    }
}

struct Environment<'a> {
    core: &'a Core,
    name: String,
    timeout: Duration,
    cancel: CancellationToken,
    hits: Vec<Value>,
}

impl Environment<'_> {
    async fn send(
        &mut self,
        url: &str,
        limit: u64,
        method: &str,
        body: &str,
        headers: Value,
        no_redirect: bool,
    ) -> Option<probe::Answer> {
        let engine = self.core.active().ok()?;
        let arguments=self.core.probe_arguments(&json!({"url":url,"proxy-name":self.name,"timeout":self.timeout.as_millis()as u64,"max-body":limit,"method":method,"body":body,"headers":headers,"no-redirect":no_redirect}));
        tokio::select! {
            _=self.cancel.cancelled()=>None,
            result=probe::request(engine,&arguments)=>{
                match result{
                    Ok(answer)=>{merge_hits(&mut self.hits,&answer.value["hits"]);Some(answer)}
                    Err(error)=>Some(probe::Answer{value:json!({"error":probe::error_kind(&error),"message":format!("{error:#}"),"delay":0,"chains":[],"body":"","status-code":0}),headers:HashMap::new(),bytes:Vec::new()}),
                }
            }
        }
    }
    async fn get(&mut self, url: &str, limit: u64) -> Option<probe::Answer> {
        self.send(url, limit, "GET", "", Value::Null, false).await
    }
}

async fn services(core: &Core, arguments: &Value) -> protocol::Result<Value> {
    static CLAIMS: OnceLock<parking_lot::Mutex<HashMap<String, CancellationToken>>> =
        OnceLock::new();
    let names = arguments.get("names").and_then(Value::as_array);
    let selected = if names.is_none_or(Vec::is_empty) {
        SERVICES
            .iter()
            .map(|name| (*name).to_owned())
            .collect::<Vec<_>>()
    } else {
        names
            .unwrap()
            .iter()
            .filter_map(Value::as_str)
            .filter(|name| SERVICES.contains(name))
            .map(str::to_owned)
            .collect()
    };
    let claims = CLAIMS.get_or_init(Default::default);
    let parent = CancellationToken::new();
    let stamp = core.stamp();
    let timeout = probe::budget(arguments);
    let claimed = selected
        .iter()
        .map(|name| {
            let token = parent.child_token();
            if let Some(previous) = claims.lock().insert(name.clone(), token.clone()) {
                previous.cancel();
            }
            (name.clone(), token)
        })
        .collect::<Vec<_>>();
    let name = arguments["proxy-name"].as_str().unwrap_or("").to_owned();
    let operation = stream::iter(claimed.into_iter().enumerate())
        .map(|(index, (service, cancel))| {
            let stamp = stamp.clone();
            let name = name.clone();
            async move {
                let mut env = Environment {
                    core,
                    name,
                    timeout,
                    cancel: cancel.clone(),
                    hits: Vec::new(),
                };
                let mut item = check(&service, &mut env).await;
                item["name"] = json!(service);
                item["checked-at"] = json!(SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis() as u64);
                item["hits"] = json!(env.hits);
                profile::patch(&mut item, &stamp);
                if cancel.is_cancelled() {
                    item["status"] = json!("failed");
                }
                (index, item)
            }
        })
        .buffer_unordered(4)
        .collect::<Vec<_>>();
    let budget = timeout.saturating_mul(6);
    let mut results = match tokio::time::timeout(budget, operation).await {
        Ok(results) => results,
        Err(_) => {
            parent.cancel();
            selected.iter().enumerate().map(|(index,name)|{
            let mut item=json!({"name":name,"status":"timeout","checked-at":SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis()as u64,"hits":[]});profile::patch(&mut item,&stamp);(index,item)
        }).collect()
        }
    };
    parent.cancel();
    results.sort_by_key(|(index, _)| *index);
    Ok(json!(results
        .into_iter()
        .map(|(_, item)| item)
        .collect::<Vec<_>>()))
}

fn item(answer: &Option<probe::Answer>) -> Value {
    let Some(answer) = answer else {
        return json!({"status":"failed"});
    };
    match answer.value["error"].as_str().unwrap_or("") {
        "" => json!({"status":"","delay":answer.value["delay"],"chains":answer.value["chains"]}),
        "timeout" => json!({"status":"timeout"}),
        _ => json!({"status":"failed"}),
    }
}
fn code(answer: &Option<probe::Answer>) -> u64 {
    answer
        .as_ref()
        .and_then(|a| a.value["status-code"].as_u64())
        .unwrap_or(0)
}
fn body(answer: &Option<probe::Answer>) -> &str {
    answer
        .as_ref()
        .and_then(|a| a.value["body"].as_str())
        .unwrap_or("")
}
fn answered(item: &Value) -> bool {
    item["status"] == ""
}
fn status(code: u64) -> &'static str {
    match code {
        200..=299 => "available",
        401 | 403 | 429 | 451 => "restricted",
        _ => "unavailable",
    }
}
fn capture(pattern: &str, text: &str) -> String {
    regex::Regex::new(pattern)
        .ok()
        .and_then(|re| {
            re.captures(text)
                .and_then(|cap| cap.get(1).map(|m| m.as_str().to_owned()))
        })
        .unwrap_or_default()
}
fn contains(text: &str, patterns: &[&str]) -> bool {
    let text = text.to_ascii_lowercase();
    patterns.iter().any(|pattern| text.contains(pattern))
}
fn trace(text: &str, key: &str) -> String {
    text.lines()
        .find_map(|line| line.strip_prefix(&format!("{key}=")))
        .unwrap_or("")
        .trim()
        .to_owned()
}

pub fn normalize_region(code: &str) -> String {
    let code = code.trim().to_ascii_uppercase();
    if code.len() == 2 && code.bytes().all(|c| c.is_ascii_uppercase()) {
        return code;
    }
    if code.len() == 3 {
        for entry in ISO3166.as_bytes().chunks_exact(5) {
            if &entry[..3] == code.as_bytes() {
                return String::from_utf8_lossy(&entry[3..]).into();
            }
        }
    }
    String::new()
}

pub fn evaluate(name: &str, response: &Value) -> Value {
    let text = response["body"].as_str().unwrap_or("");
    let lower = text.to_ascii_lowercase();
    let http = response["status-code"].as_u64().unwrap_or(0);
    let mut item = json!({"status":status(http)});
    match name {
        "youtube" => {
            let mut region = String::new();
            for pattern in [
                r#"(?i)id=["']country-code["'][^>]*>\s*([A-Za-z]{2,3})\s*<"#,
                r#""GL"\s*:\s*"([A-Za-z]{2})""#,
                r#""countryCode"\s*:\s*"([A-Za-z]{2})""#,
                r#""country_code"\s*:\s*"([A-Za-z]{2})""#,
            ] {
                region = normalize_region(&capture(pattern, text));
                if !region.is_empty() {
                    break;
                }
            }
            item["region"] = json!(region);
            item["status"] = json!(if contains(
                text,
                &[
                    "premium is not available in your country",
                    "premium is not available in your region"
                ]
            ) {
                "unsupported-region"
            } else if (200..300).contains(&http)
                && contains(
                    text,
                    &["youtube premium", "ad-free", r#""browseid":"spunlimited""#]
                )
            {
                "available"
            } else {
                status(http)
            });
        }
        "claude" => {
            let region = normalize_region(&trace(text, "loc"));
            item["region"] = json!(region);
            item["status"] = json!(if region.is_empty() {
                "failed"
            } else if ["AF", "BY", "CN", "CU", "HK", "IR", "KP", "MO", "RU", "SY"]
                .contains(&region.as_str())
            {
                "unsupported-region"
            } else {
                "available"
            });
        }
        "gemini" => {
            let region = capture(r#",2,1,200,"([A-Z]{3})"#, text);
            item["region"] = json!(normalize_region(&region));
            item["status"] = json!(if region.is_empty() {
                "failed"
            } else if ["CHN", "RUS", "BLR", "CUB", "IRN", "PRK", "SYR", "HKG", "MAC"]
                .contains(&region.as_str())
            {
                "unsupported-region"
            } else {
                "available"
            });
        }
        "prime-video" => {
            let region = capture(r#""currentTerritory"\s*:\s*"([^"]+)""#, text);
            item["region"] = json!(normalize_region(&region));
            item["status"] = json!(if text.contains("isServiceRestricted") {
                "unsupported-region"
            } else if region.is_empty() {
                "failed"
            } else {
                "available"
            });
        }
        "spotify" => {
            let mut region = capture(r#""countryCode"\s*:\s*"([^"]+)""#, text);
            if let Some(url) = response["url"]
                .as_str()
                .and_then(|url| url::Url::parse(url).ok())
            {
                if let Some(segment) = url
                    .path_segments()
                    .and_then(|mut parts| parts.next())
                    .filter(|part| !part.is_empty() && *part != "api")
                {
                    region = segment.split('-').next().unwrap_or("").to_owned();
                }
            }
            item["region"] = json!(normalize_region(&region));
            if matches!(http, 403 | 451) || lower.contains("not available in your country") {
                item["status"] = json!("unsupported-region");
            }
        }
        "tiktok" => {
            item["region"] = json!(normalize_region(&capture(
                r#""webapp\.app-context"\s*:\s*\{[^{}]*?"region"\s*:\s*"([^"]*)""#,
                text
            )));
            item["status"] = json!(if matches!(http, 403 | 451)
                || contains(
                    text,
                    &[
                        "access denied",
                        "not available in your region",
                        "tiktok is not available"
                    ]
                ) {
                "unsupported-region"
            } else if (200..300).contains(&http) {
                "available"
            } else {
                "failed"
            });
        }
        "discord" => {
            if (200..300).contains(&http) {
                item["region"] = json!(normalize_region(&capture(
                    r#""country_code"\s*:\s*"([^"]+)""#,
                    text
                )));
            }
        }
        "bilibili" => {
            item["status"] = json!(
                match capture(r#"^\s*\{\s*"code"\s*:\s*(-?\d+)"#, text).as_str() {
                    "0" => "available",
                    "-10403" => "unsupported-region",
                    _ => "failed",
                }
            );
        }
        _ => {}
    }
    item
}

async fn check(name: &str, env: &mut Environment<'_>) -> Value {
    match name {
        "chatgpt" => return chatgpt(env).await,
        "netflix" => return netflix(env).await,
        "disney-plus" => return disney(env).await,
        "bilibili" => {
            let first=env.get("https://api.bilibili.com/pgc/player/web/playurl?avid=82846771&qn=0&type=&otype=json&ep_id=307247&fourk=1&fnver=0&fnval=16&module=bangumi",16384).await;
            let mut result = item(&first);
            if !answered(&result) {
                return result;
            }
            profile::patch(&mut result, &evaluate(name, &first.as_ref().unwrap().value));
            if result["status"] == "available" {
                result["region"] = json!("CN");
                return result;
            }
            if result["status"] != "unsupported-region" {
                return result;
            }
            let second=env.get("https://api.bilibili.com/pgc/player/web/playurl?avid=18281381&cid=29892777&qn=0&type=&otype=json&ep_id=183799&fourk=1&fnver=0&fnval=16&module=bangumi",16384).await;
            let mut result = item(&second);
            if answered(&result) {
                profile::patch(
                    &mut result,
                    &evaluate(name, &second.as_ref().unwrap().value),
                );
            }
            return result;
        }
        _ => {}
    }
    let (url, limit) = match name {
        "google" => ("https://www.google.com/generate_204", 0),
        "github" => ("https://github.com/", 0),
        "youtube" => ("https://www.youtube.com/premium?hl=en", 512 * 1024),
        "claude" => ("https://claude.ai/cdn-cgi/trace", 16384),
        "gemini" => ("https://gemini.google.com", 8 * 1024 * 1024),
        "prime-video" => ("https://www.primevideo.com", 8 * 1024 * 1024),
        "spotify" => (
            "https://www.spotify.com/api/content/v1/country-selector?platform=web&format=json",
            16384,
        ),
        "tiktok" => ("https://www.tiktok.com/", 8 * 1024 * 1024),
        "discord" => ("https://discord.com/api/v9/auth/location-metadata", 16384),
        _ => return json!({"status":"failed"}),
    };
    let answer = env.get(url, limit).await;
    let mut result = item(&answer);
    if answered(&result) {
        profile::patch(
            &mut result,
            &evaluate(name, &answer.as_ref().unwrap().value),
        );
    }
    result
}

async fn chatgpt(env: &mut Environment<'_>) -> Value {
    let ios = env.get("https://ios.chat.openai.com/", 16384).await;
    let mut result = item(&ios);
    if answered(&result) {
        result["status"] = json!(if contains(
            body(&ios),
            &["you may be connected to a disallowed isp"]
        ) {
            "disallowed-isp"
        } else if contains(body(&ios), &["sorry, you have been blocked"]) {
            "blocked"
        } else if contains(
            body(&ios),
            &["request is not allowed. please try again later."]
        ) {
            "available"
        } else {
            "failed"
        });
    }
    let location = env
        .get("https://chat.openai.com/cdn-cgi/trace", 16384)
        .await;
    if answered(&item(&location)) {
        result["region"] = json!(normalize_region(&trace(body(&location), "loc")));
    }
    let compliance = env
        .get(
            "https://api.openai.com/compliance/cookie_requirements",
            16384,
        )
        .await;
    if answered(&item(&compliance)) && contains(body(&compliance), &["unsupported_country"]) {
        result["status"] = json!("unsupported-region");
    }
    result
}

async fn netflix(env: &mut Environment<'_>) -> Value {
    let cdn=env.get("https://api.fast.com/netflix/speedtest/v2?https=true&token=YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm&urlCount=5",16384).await;
    let mut result = item(&cdn);
    if answered(&result) {
        if code(&cdn) == 403 {
            result["status"] = json!("blocked");
            return result;
        }
        if let Ok(payload) = serde_json::from_str::<Value>(body(&cdn)) {
            if let Some(country) = payload["targets"][0]["location"]["country"].as_str() {
                result["status"] = json!("available");
                result["region"] = json!(normalize_region(country));
                return result;
            }
        }
    }
    let first = env.get("https://www.netflix.com/title/81280792", 0).await;
    let mut result = item(&first);
    if !answered(&result) {
        return result;
    }
    let second = env.get("https://www.netflix.com/title/70143836", 0).await;
    if !answered(&item(&second)) {
        return item(&second);
    }
    result["status"] = json!(if code(&first) == 404 && code(&second) == 404 {
        "originals-only"
    } else if code(&first) == 403 || code(&second) == 403 {
        "unsupported-region"
    } else if matches!(code(&first), 200 | 301) || matches!(code(&second), 200 | 301) {
        "available"
    } else {
        status(code(&first))
    });
    if result["status"] == "available" {
        let location = env
            .send(
                "https://www.netflix.com/title/80018499",
                0,
                "GET",
                "",
                Value::Null,
                true,
            )
            .await;
        let region = location
            .as_ref()
            .and_then(|answer| answer.headers.get("location"))
            .and_then(|location| location.split('/').nth(3))
            .unwrap_or("")
            .split('-')
            .next()
            .unwrap_or("");
        result["region"] = json!(normalize_region(region));
    }
    result
}

async fn disney(env: &mut Environment<'_>) -> Value {
    let headers =
        json!({"authorization":DISNEY_AUTH,"content-type":"application/json; charset=UTF-8"});
    let device=env.send("https://disney.api.edge.bamgrid.com/devices",16384,"POST",r#"{"deviceFamily":"browser","applicationRuntime":"chrome","deviceProfile":"windows","attributes":{}}"#,headers,false).await;
    let mut result = item(&device);
    if !answered(&result) {
        return result;
    }
    if code(&device) == 403 {
        result["status"] = json!("blocked");
        return result;
    }
    let assertion = capture(r#""assertion"\s*:\s*"([^"]+)""#, body(&device));
    if assertion.is_empty() {
        result["status"] = json!("failed");
        return result;
    }
    let form = url::form_urlencoded::Serializer::new(String::new())
        .extend_pairs([
            (
                "grant_type",
                "urn:ietf:params:oauth:grant-type:token-exchange",
            ),
            ("latitude", "0"),
            ("longitude", "0"),
            ("platform", "browser"),
            ("subject_token", &assertion),
            (
                "subject_token_type",
                "urn:bamtech:params:oauth:token-type:device",
            ),
        ])
        .finish();
    let token = env
        .send(
            "https://disney.api.edge.bamgrid.com/token",
            16384,
            "POST",
            &form,
            json!({"authorization":DISNEY_AUTH,"content-type":"application/x-www-form-urlencoded"}),
            false,
        )
        .await;
    if !answered(&item(&token)) {
        return item(&token);
    }
    if contains(body(&token), &["forbidden-location", "403 error"]) {
        result["status"] = json!("blocked");
        return result;
    }
    let refresh = capture(r#""refresh_token"\s*:\s*"([^"]+)""#, body(&token));
    if refresh.is_empty() {
        result["status"] = json!("failed");
        return result;
    }
    let query=json!({"query":"mutation refreshToken($input: RefreshTokenInput!) { refreshToken(refreshToken: $input) { activeSession { sessionId } } }","variables":{"input":{"refreshToken":refresh}}}).to_string();
    let session = env
        .send(
            "https://disney.api.edge.bamgrid.com/graph/v1/device/graphql",
            16384,
            "POST",
            &query,
            json!({"authorization":DISNEY_AUTH,"content-type":"application/json"}),
            false,
        )
        .await;
    if !answered(&item(&session)) || body(&session).is_empty() || code(&session) >= 400 {
        result["status"] = json!("failed");
        return result;
    }
    let region = normalize_region(&capture(r#""countryCode"\s*:\s*"([^"]+)""#, body(&session)));
    if region.is_empty() {
        result["status"] = json!("unavailable");
        return result;
    }
    result["region"] = json!(region);
    result["status"] = json!(match capture(
        r#""inSupportedLocation"\s*:\s*(false|true)"#,
        body(&session)
    )
    .as_str()
    {
        "true" => "available",
        "false" => "coming-soon",
        _ => "failed",
    });
    result
}

const ISO3166:&str="ABWAWAFGAFAGOAOAIAAIALAAXALBALANDADAREAEARGARARMAMASMASATAAQATFTFATGAGAUSAUAUTATAZEAZBDIBIBELBEBENBJBESBQBFABFBGDBDBGRBGBHRBHBHSBSBIHBABLMBLBLRBYBLZBZBMUBMBOLBOBRABRBRBBBBRNBNBTNBTBVTBVBWABWCAFCFCANCACCKCCCHECHCHLCLCHNCNCIVCICMRCMCODCDCOGCGCOKCKCOLCOCOMKMCPVCVCRICRCUBCUCUWCWCXRCXCYMKYCYPCYCZECZDEUDEDJIDJDMADMDNKDKDOMDODZADZECUECEGYEGERIERESHEHESPESESTEEETHETFINFIFJIFJFLKFKFRAFRFROFOFSMFMGABGAGBRGBGEOGEGGYGGGHAGHGIBGIGINGNGLPGPGMBGMGNBGWGNQGQGRCGRGRDGDGRLGLGTMGTGUFGFGUMGUGUYGYHKGHKHMDHMHNDHNHRVHRHTIHTHUNHUIDNIDIMNIMINDINIOTIOIRLIEIRNIRIRQIQISLISISRILITAITJAMJMJEYJEJORJOJPNJPKAZKZKENKEKGZKGKHMKHKIRKIKNAKNKORKRKWTKWLAOLALBNLBLBRLRLBYLYLCALCLIELILKALKLSOLSLTULTLUXLULVALVMACMOMAFMFMARMAMCOMCMDAMDMDGMGMDVMVMEXMXMHLMHMKDMKMLIMLMLTMTMMRMMMNEMEMNGMNMNPMPMOZMZMRTMRMSRMSMTQMQMUSMUMWIMWMYSMYMYTYTNAMNANCLNCNERNENFKNFNGANGNICNINIUNUNLDNLNORNONPLNPNRUNRNZLNZOMNOMPAKPKPANPAPCNPNPERPEPHLPHPLWPWPNGPGPOLPLPRIPRPRKKPPRTPTPRYPYPSEPSPYFPFQATQAREUREROURORUSRURWARWSAUSASDNSDSENSNSGPSGSGSGSSHNSHSJMSJSLBSBSLESLSLVSVSMRSMSOMSOSPMPMSRBRSSSDSSSTPSTSURSRSVKSKSVNSISWESESWZSZSXMSXSYCSCSYRSYTCATCTCDTDTGOTGTHATHTJKTJTKLTKTKMTMTLSTLTONTOTTOTTTUNTNTURTRTUVTVTWNTWTZATZUGAUGUKRUAUMIUMURYUYUSAUSUZBUZVATVAVCTVCVENVEVGBVGVIRVIVNMVNVUTVUWLFWFWSMWSYEMYEZAFZAZMBZMZWEZW";
