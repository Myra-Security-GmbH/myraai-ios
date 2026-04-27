package eu.myra.myraai

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import androidx.core.app.NotificationCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * MyraFirebaseMessagingService — handles FCM token rotation and incoming
 * data-only push payloads from the backend.
 *
 * Payload contract (set by src/push/fcm_service.py):
 *   data.title             — notification title (always present)
 *   data.body              — notification body  (always present)
 *   data.kind              — "chat_reply" | "project_invite" | other
 *   data.conversation_id   — optional, used to deep-link when the user taps
 *
 * The backend always sends data-only payloads (no FCM "notification" field)
 * so onMessageReceived fires consistently in both foreground and background
 * states and we keep full control over channel selection, click actions, and
 * styling.
 */
class MyraFirebaseMessagingService : FirebaseMessagingService() {

    override fun onNewToken(token: String) {
        Log.d(TAG, "FCM onNewToken (len=${token.length})")
        // Cache the latest token so the WebView can fetch it via the
        // NativeBridge.getDeviceToken() bridge call after sign-in. Mirrors
        // the iOS NativeBridge.pendingDeviceToken pattern.
        latestToken = token
        // Notify any open WebView so it can immediately resync the token to
        // the backend (instead of waiting for the next manual fetch).
        MainActivity.notifyDeviceTokenChanged(token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        val title = data["title"] ?: getString(R.string.app_name)
        val body  = data["body"]  ?: ""
        val kind  = data["kind"]  ?: "general"

        val channelId = when (kind) {
            "chat_reply" -> getString(R.string.notification_channel_chat)
            else         -> getString(R.string.notification_channel_general)
        }

        // Deep-link target: open the conversation if we have one, otherwise the home screen.
        val deepLink = data["conversation_id"]?.let { convId ->
            Uri.parse("https://ai.myra.eu/chat?conv=$convId")
        } ?: Uri.parse("https://ai.myra.eu/")

        val tapIntent = Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            this.data = deepLink
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pending = PendingIntent.getActivity(
            this, message.messageId.hashCode(), tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notif = NotificationCompat.Builder(this, channelId)
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(getColor(R.color.notification_color))
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(pending)
            .setAutoCancel(true)
            .setDefaults(NotificationCompat.DEFAULT_SOUND or NotificationCompat.DEFAULT_VIBRATE)
            .build()

        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(message.messageId.hashCode(), notif)
    }

    companion object {
        private const val TAG = "MyraFCM"

        // Most-recent FCM token. Read by NativeBridge.getDeviceToken when the
        // WebView asks. Volatile because it's written from the FCM service
        // thread and read from the main thread.
        @Volatile
        var latestToken: String? = null
    }
}
