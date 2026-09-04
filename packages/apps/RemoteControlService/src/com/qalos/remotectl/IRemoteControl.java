// SPDX-License-Identifier: Apache-2.0
/*
 * qalos — Remote Control Service internal interface.
 *
 * v0 is same-process only: the HttpApiServer (also in system_server)
 * calls these methods directly on the service instance. There is no
 * AIDL Binder publication in v0; the only external surface is the
 * HTTP/JSON API on 127.0.0.1:9000.
 *
 * Why not AIDL? The services.core-sources filegroup globs every
 * .java file under java/ but does not match .aidl files. The
 * standard AOSP pattern is to put AIDL in core/java/android/<pkg>/
 * and declare it in frameworks/base/Android.bp's aidl_interface
 * block. For v0, with no privileged client binding to the service
 * over Binder, the plain Java interface is the right shape. A v1+
 * that wants Binder can re-introduce the AIDL by moving it to
 * core/java/android/os/ and patching frameworks/base/Android.bp.
 *
 * The interface is in the com.qalos.remotectl package on purpose:
 * the service and the HTTP server are both in this package, and
 * the interface is a private contract between them.
 */
package com.qalos.remotectl;

/**
 * Internal contract between {@link RemoteControlService} and
 * {@link HttpApiServer}. See the HTTP API reference for the
 * on-wire shape that each method backs.
 */
interface IRemoteControl {
    // --- Input ---
    void tap(int x, int y, int displayId);
    void typeText(String text);
    void keyEvent(int keyCode, boolean down);

    // --- App lifecycle ---
    void launchApp(String packageName);
    void forceStop(String packageName);

    // --- Queries ---
    String getForegroundPackage();
    int getDisplayWidth(int displayId);
    int getDisplayHeight(int displayId);

    // --- Screenshot (returns a base64-encoded PNG so the HTTP layer
    //     does not need to encode it again). ---
    String screenshotBase64(int width, int height, int displayId, int quality);
}
