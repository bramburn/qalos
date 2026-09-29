package com.google.android.gms.common;

import com.google.android.gms.common.api.GoogleApiClient;

/**
 * Stub implementation of GoogleApi for the qalos AOSP build.
 */
public abstract class GoogleApi {

    protected GoogleApi() {
    }

    public abstract void connect();

    public abstract void disconnect();

    public abstract boolean isConnected();
}
