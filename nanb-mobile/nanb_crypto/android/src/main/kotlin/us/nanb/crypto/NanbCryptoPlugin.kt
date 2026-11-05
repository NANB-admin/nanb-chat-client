package us.nanb.crypto

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * FlutterPlugin wrapper for [NanbCryptoChannel]. Living in a pubspec-listed
 * plugin package (instead of a manual MainActivity registration) means
 * `GeneratedPluginRegistrant` attaches it to EVERY FlutterEngine — crucially
 * including the engine firebase_messaging spawns for the background isolate,
 * which never goes through MainActivity. Without this, background-isolate
 * `nanb.crypto` calls died with MissingPluginException and push previews
 * could never decrypt.
 *
 * State note: [MlsClientHolder] is a process-wide singleton, so the
 * foreground and background engines share one CoreCrypto instance — exactly
 * one open store per process, per spec §7.3.
 */
class NanbCryptoPlugin : FlutterPlugin {
    private var channel: MethodChannel? = null
    private var callChannel: MethodChannel? = null
    private var torMethodChannel: MethodChannel? = null
    private var torEventChannel: EventChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val handler = NanbCryptoChannel(binding.applicationContext)
        channel = MethodChannel(binding.binaryMessenger, "nanb.crypto").also {
            it.setMethodCallHandler(handler::onCall)
        }
        // Piggy-back on this plugin's every-engine registration (incl. the FCM
        // background isolate) to expose native incoming-call notification posting,
        // whose full-screen intent targets the native IncomingCallActivity. See
        // CallNotificationChannel for why the call ring can't go through
        // flutter_local_notifications.
        val callHandler = CallNotificationChannel(binding.applicationContext)
        callChannel = MethodChannel(binding.binaryMessenger, CallNotificationChannel.CHANNEL_NAME)
            .also { it.setMethodCallHandler(callHandler::onCall) }

        // Embedded Tor (docs/embedded-tor-design.md, M1): a method channel drives
        // start/stop and an event channel streams bootstrap status + the SOCKS
        // port. Registered on every engine like the channels above; only the
        // foreground isolate actually drives it.
        val torHandler = TorChannel(binding.applicationContext)
        torMethodChannel = MethodChannel(binding.binaryMessenger, TorChannel.METHOD_CHANNEL)
            .also { it.setMethodCallHandler(torHandler::onMethodCall) }
        torEventChannel = EventChannel(binding.binaryMessenger, TorChannel.EVENT_CHANNEL)
            .also { it.setStreamHandler(torHandler) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        callChannel?.setMethodCallHandler(null)
        callChannel = null
        torMethodChannel?.setMethodCallHandler(null)
        torMethodChannel = null
        torEventChannel?.setStreamHandler(null)
        torEventChannel = null
    }
}
