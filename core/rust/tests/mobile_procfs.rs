use flclash::mobile::procfs::parse_uid_table;

const HEADER: &str =
    "  sl  local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n";

#[test]
fn linux_proc_header_collapses_queue_and_timer_pairs() {
    let table = format!("{HEADER} 0: 0100007F:9470 0A6433C6:01BB 01 00000000:00000000 00:00000000 00000000 10234 0 12345\n");
    assert_eq!(
        parse_uid_table(
            &table,
            "127.0.0.1:38000".parse().unwrap(),
            "198.51.100.10:443".parse().unwrap()
        ),
        Some(10234)
    );
    assert_eq!(
        parse_uid_table(
            &table,
            "127.0.0.1:38001".parse().unwrap(),
            "198.51.100.10:443".parse().unwrap()
        ),
        None
    );
    assert_eq!(
        parse_uid_table(
            &table,
            "127.0.0.1:38000".parse().unwrap(),
            "198.51.100.11:443".parse().unwrap()
        ),
        None
    );
}

#[test]
fn ipv6_proc_words_are_little_endian_independently() {
    let table = format!("{HEADER}0: B80D0120000000000000000002000000:9470 B80D0120000000000000000003000000:01BB 01 0:0 00:0 0 333 0 7\n");
    assert_eq!(
        parse_uid_table(
            &table,
            "[2001:db8::2]:38000".parse().unwrap(),
            "[2001:db8::3]:443".parse().unwrap()
        ),
        Some(333)
    );
}

#[test]
fn ipv4_mapped_ipv6_tables_keep_android_dual_stack_owners() {
    let table = format!("{HEADER}0: 0000000000000000FFFF00000100007F:9470 0000000000000000FFFF00000A6433C6:01BB 01 0:0 00:0 0 444 0 7\n");
    assert_eq!(
        parse_uid_table(
            &table,
            "127.0.0.1:38000".parse().unwrap(),
            "198.51.100.10:443".parse().unwrap()
        ),
        Some(444)
    );
}

#[test]
fn exact_peer_precedes_unconnected_and_wildcard_udp_bindings() {
    let table = format!("{HEADER}0: 00000000:9470 00000000:0000 07 0:0 00:0 0 1 0 7\n1: 0100007F:9470 00000000:0000 07 0:0 00:0 0 2 0 7\n2: 0100007F:9470 0A6433C6:01BB 01 0:0 00:0 0 3 0 7\n");
    assert_eq!(
        parse_uid_table(
            &table,
            "127.0.0.1:38000".parse().unwrap(),
            "198.51.100.10:443".parse().unwrap()
        ),
        Some(3)
    );
    let wildcard = format!("{HEADER}0: 00000000:9470 00000000:0000 07 0:0 00:0 0 555 0 7\n");
    assert_eq!(
        parse_uid_table(
            &wildcard,
            "10.0.0.2:38000".parse().unwrap(),
            "198.51.100.10:443".parse().unwrap()
        ),
        Some(555)
    );
}

#[test]
fn malformed_or_unavailable_proc_rows_do_not_invent_uid_zero() {
    let source = "127.0.0.1:38000".parse().unwrap();
    let target = "198.51.100.10:443".parse().unwrap();
    for table in [
        String::new(),
        "sl uid\n0: 0".into(),
        format!("{HEADER}0: not-an-address missing\n"),
        format!("{HEADER}0: 0100007F:9470 0A6433C6:01BB 01 0:0 00:0 0 invalid 0 7\n"),
    ] {
        assert_eq!(parse_uid_table(&table, source, target), None);
    }
}
