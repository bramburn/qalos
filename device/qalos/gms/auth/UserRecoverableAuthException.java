package com.google.android.gms.auth;

import android.os.Bundle;

/**
 * Stub implementation of UserRecoverableAuthException for the qalos AOSP build.
 */
public class UserRecoverableAuthException extends Exception {

    private final Bundle mBundle;

    public UserRecoverableAuthException(String message, Bundle bundle) {
        super(message);
        mBundle = bundle;
    }

    public Bundle getIntent() {
        return mBundle;
    }
}
