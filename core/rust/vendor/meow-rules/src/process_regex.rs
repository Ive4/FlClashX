use meow_common::{Metadata, Rule, RuleMatchHelper, RuleType};
use regex::Regex;
use smol_str::SmolStr;

use crate::adapter::{intern_adapter, Adapter};

pub struct ProcessRegexRule {
    regex: Regex,
    pattern: SmolStr,
    adapter: Adapter,
    path: bool,
}

impl ProcessRegexRule {
    pub fn new(pattern: &str, adapter: &str, path: bool) -> Result<Self, regex::Error> {
        Ok(Self {
            regex: Regex::new(pattern)?,
            pattern: pattern.into(),
            adapter: intern_adapter(adapter),
            path,
        })
    }
}

impl Rule for ProcessRegexRule {
    fn rule_type(&self) -> RuleType {
        if self.path {
            RuleType::ProcessPathRegex
        } else {
            RuleType::ProcessNameRegex
        }
    }

    fn match_metadata(&self, metadata: &Metadata, _helper: &RuleMatchHelper) -> bool {
        let value = if self.path {
            &metadata.process_path
        } else {
            &metadata.process
        };
        !value.is_empty() && self.regex.is_match(value)
    }

    fn adapter(&self) -> &str {
        &self.adapter
    }

    fn payload(&self) -> &str {
        &self.pattern
    }

    fn should_find_process(&self) -> bool {
        meow_common::process_lookup::PROCESS_LOOKUP_SUPPORTED
    }

    fn never_matches(&self) -> bool {
        !meow_common::process_lookup::process_info_available()
    }
}
