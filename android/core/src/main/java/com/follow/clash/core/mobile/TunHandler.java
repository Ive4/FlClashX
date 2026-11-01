package com.follow.clash.core.mobile;

public interface TunHandler {
    boolean protect(int fd);
    int resolveUid(int protocol, String source, String target);
    String resolvePackage(int uid);
}
