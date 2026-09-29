package com.google.android.gms.common;

import android.content.Context;

/**
 * Stub permissions class for microG-based GMS mimic.
 * Grants no special permissions — apps that check GMS permission status
 * will receive false/denied for all privileged calls.
 */
public final class GmsPermissions {

    public static boolean holdsPermission(Context ctx, String permission) {
        return false; // microG stub: no special permissions granted
    }
}
