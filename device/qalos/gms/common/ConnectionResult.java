package com.google.android.gms.common;

/**
 * Stub implementation of ConnectionResult for the qalos AOSP build.
 */
public class ConnectionResult {

    public static final int SUCCESS = 0;
    public static final int SERVICE_MISSING = 1;
    public static final int SERVICE_VERSION_UPDATE_REQUIRED = 2;
    public static final int SERVICE_DISABLED = 3;
    public static final int SIGN_IN_REQUIRED = 4;
    public static final int INVALID_ACCOUNT = 5;
    public static final int RESOLUTION_REQUIRED = 6;
    public static final int NETWORK_ERROR = 7;
    public static final int INTERNAL_ERROR = 8;
    public static final int TIMEOUT = 9;
    public static final int API_DISABLED = 10;
    public static final int CANCELED = 11;
    public static final int API_UNAVAILABLE = 12;
    public static final int DEVELOPER_ERROR = 13;

    private final int mErrorCode;

    public ConnectionResult(int statusCode) {
        mErrorCode = statusCode;
    }

    public ConnectionResult(int statusCode, android.app.PendingIntent pendingIntent) {
        mErrorCode = statusCode;
    }

    public int getErrorCode() {
        return mErrorCode;
    }

    public boolean isSuccess() {
        return mErrorCode == SUCCESS;
    }
}
