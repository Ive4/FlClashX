package com.follow.clash.core.mobile;

public final class Mobile {
    static {
        System.loadLibrary("flclash");
    }

    private Mobile() {}

    public static native byte[] backupCodec(byte[] request);
    public static native void invokeMethod(String data, ResultHandler handler);
    public static native void quickSetup(String initParams, String setupParams, ResultHandler handler);
    public static native void setEventListener(ResultHandler handler);
    public static native boolean startTun(int fd, TunHandler handler, String stack, String address, String dns, String options);
    public static native void stopTun();
    public static native void startListener();
    public static native void stopListener();
    public static native void forceGC();
    public static native void updateDns(String value);
    public static native void resetNetwork();
    public static native String getTraffic(boolean onlyStatisticsProxy);
    public static native String getTotalTraffic(boolean onlyStatisticsProxy);
}
