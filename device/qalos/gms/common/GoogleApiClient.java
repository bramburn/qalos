package com.google.android.gms.common;

/**
 * Stub implementation of GoogleApiClient for the qalos AOSP build.
 */
public interface GoogleApiClient {

    interface ConnectionCallbacks {
        void onConnected(Bundle bundle);
        void onConnectionSuspended(int cause);
    }

    interface OnConnectionFailedListener {
        void onConnectionFailed(ConnectionResult result);
    }

    void connect();
    void disconnect();
    boolean isConnected();
    void registerConnectionCallbacks(ConnectionCallbacks callback);
    void unregisterConnectionCallbacks(ConnectionCallbacks callback);
    void registerConnectionFailedListener(OnConnectionFailedListener listener);
    void unregisterConnectionFailedListener(OnConnectionFailedListener listener);
}
