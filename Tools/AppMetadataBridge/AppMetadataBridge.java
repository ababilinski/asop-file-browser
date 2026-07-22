package com.asopfilebrowser.metadata;

import android.content.res.AssetManager;
import android.content.res.Resources;
import android.content.res.XmlResourceParser;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.BitmapDrawable;
import android.graphics.drawable.Drawable;
import android.util.Base64;
import android.util.DisplayMetrics;

import org.xmlpull.v1.XmlPullParser;

import java.io.ByteArrayOutputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.Method;

/**
 * Reads installed-app labels and icons from each APK's own resources.
 *
 * This helper is run temporarily with app_process over an existing debugging
 * connection. It is not installed as an Android application.
 */
public final class AppMetadataBridge {
    private static final int ICON_SIZE_PX = 128;
    private static final String ANDROID_NAMESPACE = "http://schemas.android.com/apk/res/android";

    private AppMetadataBridge() {}

    public static void main(String[] arguments) {
        for (int index = 0; index + 1 < arguments.length; index += 2) {
            String packageName = arguments[index];
            String apkPath = arguments[index + 1];
            try {
                AppMetadata metadata = readMetadata(apkPath);
                System.out.println(
                        packageName + "\t" + sanitize(metadata.label) + "\t" + encodeIcon(metadata.icon)
                );
            } catch (Throwable error) {
                System.out.println(packageName + "\t\t");
            }
        }
    }

    private static AppMetadata readMetadata(String apkPath) throws Exception {
        Constructor<AssetManager> constructor = AssetManager.class.getDeclaredConstructor();
        constructor.setAccessible(true);
        AssetManager assets = constructor.newInstance();
        Method addAssetPath = AssetManager.class.getDeclaredMethod("addAssetPath", String.class);
        addAssetPath.setAccessible(true);
        int cookie = (Integer) addAssetPath.invoke(assets, apkPath);
        if (cookie == 0) {
            throw new IllegalStateException("Could not open APK resources");
        }

        Resources system = Resources.getSystem();
        Resources resources = new Resources(
                assets,
                system.getDisplayMetrics(),
                system.getConfiguration()
        );

        try (XmlResourceParser parser = assets.openXmlResourceParser(cookie, "AndroidManifest.xml")) {
            while (parser.next() != XmlPullParser.END_DOCUMENT) {
                if (parser.getEventType() != XmlPullParser.START_TAG
                        || !"application".equals(parser.getName())) {
                    continue;
                }

                String label = readLabel(parser, resources);
                Drawable icon = readIcon(parser, resources);
                return new AppMetadata(label, icon);
            }
        }
        throw new IllegalStateException("APK manifest has no application element");
    }

    private static String readLabel(XmlResourceParser parser, Resources resources) {
        int labelResource = parser.getAttributeResourceValue(ANDROID_NAMESPACE, "label", 0);
        if (labelResource != 0) {
            try {
                return resources.getString(labelResource);
            } catch (Resources.NotFoundException ignored) {}
        }

        String literal = parser.getAttributeValue(ANDROID_NAMESPACE, "label");
        return literal == null || literal.startsWith("@") ? "" : literal;
    }

    private static Drawable readIcon(XmlResourceParser parser, Resources resources) {
        int iconResource = parser.getAttributeResourceValue(ANDROID_NAMESPACE, "roundIcon", 0);
        if (iconResource == 0) {
            iconResource = parser.getAttributeResourceValue(ANDROID_NAMESPACE, "icon", 0);
        }
        if (iconResource == 0) {
            return null;
        }

        try {
            return resources.getDrawableForDensity(
                    iconResource,
                    DisplayMetrics.DENSITY_XXHIGH,
                    null
            );
        } catch (Resources.NotFoundException ignored) {
            return resources.getDrawable(iconResource, null);
        }
    }

    private static String encodeIcon(Drawable drawable) {
        if (drawable == null) {
            return "";
        }
        Bitmap bitmap;
        if (drawable instanceof BitmapDrawable
                && ((BitmapDrawable) drawable).getBitmap() != null) {
            Bitmap source = ((BitmapDrawable) drawable).getBitmap();
            bitmap = Bitmap.createScaledBitmap(source, ICON_SIZE_PX, ICON_SIZE_PX, true);
        } else {
            bitmap = Bitmap.createBitmap(
                    ICON_SIZE_PX,
                    ICON_SIZE_PX,
                    Bitmap.Config.ARGB_8888
            );
            Canvas canvas = new Canvas(bitmap);
            drawable.setBounds(0, 0, ICON_SIZE_PX, ICON_SIZE_PX);
            drawable.draw(canvas);
        }

        ByteArrayOutputStream output = new ByteArrayOutputStream();
        bitmap.compress(Bitmap.CompressFormat.PNG, 90, output);
        return Base64.encodeToString(output.toByteArray(), Base64.NO_WRAP);
    }

    private static String sanitize(String value) {
        return value
                .replace('\t', ' ')
                .replace('\n', ' ')
                .replace('\r', ' ')
                .trim();
    }

    private static final class AppMetadata {
        final String label;
        final Drawable icon;

        AppMetadata(String label, Drawable icon) {
            this.label = label;
            this.icon = icon;
        }
    }
}
