package com.google.android.gms.auth;

import android.content.Context;

/**
 * Stub implementation of Auth for the qalos AOSP build.
 */
public final class Auth {

    private Auth() {
    }

    /**
     * Stub implementation that always throws UserRecoverableAuthException.
     * Real GmsCore functionality requires the actual GmsCore APK.
     */
    public static String getToken(Context context, String accountName, String scope)
            throws UserRecoverableAuthException {
        throw new UserRecoverableAuthException(
                "GmsCore not implemented",
                new android.os.Bundle());
    }
}
