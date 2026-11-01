package com.follow.clash.core.mobile;

@FunctionalInterface
public interface ResultHandler {
    void onResult(byte[] data);
}
