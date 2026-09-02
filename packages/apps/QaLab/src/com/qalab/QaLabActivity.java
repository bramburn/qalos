package com.qalab;

import android.app.Activity;
import android.os.Build;
import android.os.Bundle;
import android.view.Gravity;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * QaLab — the only first-party app that ships with qalos. It prints the build's
 * identifying metadata so a tester can confirm at a glance that the running AVD
 * is a real qalos build (and not stock AOSP).
 */
public class QaLabActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setGravity(Gravity.CENTER);
        layout.setPadding(48, 48, 48, 48);

        TextView title = new TextView(this);
        title.setText("qalos — QA Lab Operating System");
        title.setTextSize(22f);
        title.setGravity(Gravity.CENTER);
        layout.addView(title);

        TextView subtitle = new TextView(this);
        subtitle.setText("\nBuild metadata:");
        subtitle.setTextSize(14f);
        layout.addView(subtitle);

        TextView props = new TextView(this);
        props.setTextSize(12f);
        props.setText(String.format(
            "  Build.ID:        %s%n" +
            "  Display ID:      %s%n" +
            "  Product:         %s%n" +
            "  Device:          %s%n" +
            "  Brand:           %s%n" +
            "  Manufacturer:    %s%n" +
            "  Model:           %s%n" +
            "  Android release: %s%n" +
            "  SDK:             %d%n",
            Build.DISPLAY,
            System.getProperty("ro.build.display.id", "?"),
            Build.PRODUCT,
            Build.DEVICE,
            Build.BRAND,
            Build.MANUFACTURER,
            Build.MODEL,
            Build.VERSION.RELEASE,
            Build.VERSION.SDK_INT
        ));
        layout.addView(props);

        setContentView(layout);
    }
}
