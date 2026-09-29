package com.google.android.gms;

import android.content.Context;

/**
 * Stub implementation of GmsCore for the qalos AOSP build.
 * This is a minimal placeholder that allows compilation of GmsCore-dependent apps.
 */
public final class GmsCore {

    private static GmsCore sInstance;

    private GmsCore() {
    }

    public static synchronized GmsCore getInstance() {
        if (sInstance == null) {
            sInstance = new GmsCore();
        }
        return sInstance;
    }
}
