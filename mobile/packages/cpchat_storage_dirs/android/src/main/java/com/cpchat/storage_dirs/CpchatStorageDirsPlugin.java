package com.cpchat.storage_dirs;

import android.content.Context;
import androidx.annotation.Keep;
import androidx.annotation.NonNull;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

/**
 * Exposes Android Context storage directories (`noBackupFilesDir`, `cacheDir`)
 * as a registered FlutterPlugin so GeneratedPluginRegistrant attaches it to
 * both the main FlutterEngine and headless background engines (such as FCM's
 * FLTFireBGExecutor) where MainActivity is never instantiated.
 */
@Keep
public class CpchatStorageDirsPlugin implements FlutterPlugin, MethodCallHandler {
  private static final String CHANNEL_NAME = "cpchat/storage";

  private MethodChannel channel;
  private Context applicationContext;

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    applicationContext = binding.getApplicationContext();
    channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL_NAME);
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
    final Context context = applicationContext;
    if (context == null) {
      result.error("detached", "CpchatStorageDirsPlugin is not attached to a Context", null);
      return;
    }
    switch (call.method) {
      case "getNoBackupFilesDir":
        result.success(context.getNoBackupFilesDir().getAbsolutePath());
        break;
      case "getCacheDir":
        result.success(context.getCacheDir().getAbsolutePath());
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    if (channel != null) {
      channel.setMethodCallHandler(null);
      channel = null;
    }
    applicationContext = null;
  }
}
