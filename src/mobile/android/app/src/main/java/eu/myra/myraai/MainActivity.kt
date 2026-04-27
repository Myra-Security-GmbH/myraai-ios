package eu.myra.myraai

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.view.View
import android.view.ViewGroup
import android.webkit.*
import android.widget.Button
import android.widget.ProgressBar
import android.widget.TextView
import androidx.activity.OnBackPressedCallback
import android.accounts.AccountManager
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.swiperefreshlayout.widget.SwipeRefreshLayout

class MainActivity : AppCompatActivity() {

    private lateinit var webView: WebView
    private lateinit var offlineView: View
    private lateinit var swipeRefresh: SwipeRefreshLayout
    private lateinit var progressBar: ProgressBar
    private lateinit var retryButton: Button
    private lateinit var offlineTitleView: TextView
    private lateinit var offlineMessageView: TextView
    private var filePathCallback: ValueCallback<Array<Uri>>? = null
    private var isPageLoaded = false
    private var splashExpired = false

    private lateinit var hintLauncher: ActivityResultLauncher<Intent>

    private val filePickerLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        val uris: Array<Uri>? = if (result.resultCode == Activity.RESULT_OK)
            result.data?.data?.let { arrayOf(it) } else null
        filePathCallback?.onReceiveValue(uris)
        filePathCallback = null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        val splashScreen = installSplashScreen()
        super.onCreate(savedInstanceState)

        // Dismiss the splash after 5 s at the latest so a slow first load doesn't
        // leave the user on a frozen splash screen with no feedback.
        Handler(Looper.getMainLooper()).postDelayed({
            splashExpired = true
        }, SPLASH_TIMEOUT_MS)
        splashScreen.setKeepOnScreenCondition { !isPageLoaded && !splashExpired }

        WindowCompat.setDecorFitsSystemWindows(window, false)
        setContentView(R.layout.activity_main)

        webView          = findViewById(R.id.webview)
        offlineView      = findViewById(R.id.offline_view)
        swipeRefresh     = findViewById(R.id.swipe_refresh)
        progressBar      = findViewById(R.id.progress_bar)
        retryButton      = findViewById(R.id.retry_button)
        offlineTitleView = findViewById(R.id.offline_title)
        offlineMessageView = findViewById(R.id.offline_message)

        hintLauncher = registerForActivityResult(
            ActivityResultContracts.StartActivityForResult()
        ) { result ->
            if (result.resultCode == Activity.RESULT_OK) {
                result.data?.getStringExtra(AccountManager.KEY_ACCOUNT_NAME)
                    ?.let { injectEmailWhenReady(it) }
            }
        }

        swipeRefresh.setColorSchemeColors(getColor(R.color.myra_blue))
        // Only allow pull-to-refresh when the WebView is truly at the top.
        // canScrollVertically(-1) is the reliable native check — no JS bridge needed.
        swipeRefresh.setOnChildScrollUpCallback { _, _ -> webView.canScrollVertically(-1) }
        swipeRefresh.setOnRefreshListener {
            isPageLoaded = false
            webView.reload()
        }

        retryButton.setOnClickListener {
            retryButton.isEnabled = false
            retryButton.text = getString(R.string.retrying)
            offlineView.visibility = View.GONE
            swipeRefresh.visibility = View.VISIBLE
            isPageLoaded = false
            webView.reload()
        }

        // Use margins on swipeRefresh (not padding) so the web viewport adjusts for
        // system bars and the IME. Moving the view boundary is the only way to signal
        // the WebView about available space.
        ViewCompat.setOnApplyWindowInsetsListener(swipeRefresh) { view, insets ->
            val systemBars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            val ime = insets.getInsets(WindowInsetsCompat.Type.ime())
            val topInset = systemBars.top
            val bottomInset = maxOf(systemBars.bottom, ime.bottom)
            (view.layoutParams as? ViewGroup.MarginLayoutParams)?.apply {
                topMargin = topInset
                bottomMargin = bottomInset
            }
            view.requestLayout()
            (offlineView.layoutParams as? ViewGroup.MarginLayoutParams)?.apply {
                topMargin = topInset
                bottomMargin = systemBars.bottom
            }
            offlineView.requestLayout()
            (progressBar.layoutParams as? ViewGroup.MarginLayoutParams)?.apply {
                topMargin = topInset
            }
            progressBar.requestLayout()
            insets
        }

        // Predictive back gesture (Android 13+) and back-in-webview on older devices.
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                if (webView.canGoBack()) webView.goBack()
                else { isEnabled = false; onBackPressedDispatcher.onBackPressed() }
            }
        })

        registerNetworkCallback()
        setupWebView()

        val startUrl = intent?.data?.toString() ?: HOME_URL
        webView.loadUrl(startUrl)
    }

    private fun setupWebView() {
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false  // app only loads https://ai.myra.eu — no local file access needed
            userAgentString = "$userAgentString MYRAai-Android/${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})"
            // Respect the device accessibility font-size setting.
            textZoom = (resources.configuration.fontScale * 100).toInt()
        }

        // Remove the blue edge-glow overscroll effect — the web app has its own.
        webView.overScrollMode = View.OVER_SCROLL_NEVER

        webView.importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_YES

        // Prevent Android from algorithmically force-darkening web content; the web
        // app manages its own theme via localStorage so OS darkening would conflict.
        if (Build.VERSION.SDK_INT >= 33) {
            webView.settings.setAlgorithmicDarkeningAllowed(false)
        } else if (Build.VERSION.SDK_INT >= 29) {
            @Suppress("DEPRECATION")
            webView.settings.forceDark = WebSettings.FORCE_DARK_OFF
        }

        // Suppress the WebView built-in long-press context menu for links/images
        // (shows "Open in new tab" which is meaningless with no tab bar).
        webView.setOnLongClickListener {
            val result = webView.hitTestResult
            result.type == WebView.HitTestResult.SRC_ANCHOR_TYPE ||
            result.type == WebView.HitTestResult.IMAGE_TYPE ||
            result.type == WebView.HitTestResult.SRC_IMAGE_ANCHOR_TYPE
        }

        // Native bridge — lets the web app call Android APIs via window.Android.*
        webView.addJavascriptInterface(NativeBridge(this), "Android")

        CookieManager.getInstance().apply {
            setAcceptCookie(true)
            setAcceptThirdPartyCookies(webView, true)
        }

        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(
                view: WebView,
                request: WebResourceRequest
            ): Boolean {
                val host = request.url.host ?: return false
                return if (host.endsWith("myra.eu")) false
                else { startActivity(Intent(Intent.ACTION_VIEW, request.url)); true }
            }

            override fun onPageFinished(view: WebView, url: String) {
                isPageLoaded = true
                swipeRefresh.isRefreshing = false
                // Reset retry button so it's ready for the next failure
                retryButton.isEnabled = true
                retryButton.text = getString(R.string.retry)
                if (url.contains("/login")) showEmailHint()
            }

            override fun onReceivedError(
                view: WebView,
                request: WebResourceRequest,
                error: WebResourceError
            ) {
                if (request.isForMainFrame) {
                    val (title, message) = when (error.errorCode) {
                        WebViewClient.ERROR_HOST_LOOKUP -> {
                            getString(R.string.offline_title_dns) to
                                getString(R.string.offline_message_dns)
                        }
                        WebViewClient.ERROR_CONNECT,
                        WebViewClient.ERROR_TIMEOUT -> {
                            getString(R.string.offline_title_server) to
                                getString(R.string.offline_message_server)
                        }
                        else -> {
                            getString(R.string.offline_title) to
                                getString(R.string.offline_message)
                        }
                    }
                    offlineTitleView.text = title
                    offlineMessageView.text = message
                    retryButton.isEnabled = true
                    retryButton.text = getString(R.string.retry)
                    swipeRefresh.visibility = View.GONE
                    offlineView.visibility = View.VISIBLE
                    swipeRefresh.isRefreshing = false
                }
            }
        }

        webView.webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView, newProgress: Int) {
                progressBar.progress = newProgress
                progressBar.visibility = if (newProgress == 100) View.GONE else View.VISIBLE
            }

            override fun onShowFileChooser(
                webView: WebView,
                filePathCallback: ValueCallback<Array<Uri>>,
                fileChooserParams: FileChooserParams
            ): Boolean {
                this@MainActivity.filePathCallback?.onReceiveValue(null)
                this@MainActivity.filePathCallback = filePathCallback
                val intent = try {
                    fileChooserParams.createIntent()
                } catch (e: Exception) {
                    filePathCallback.onReceiveValue(null)
                    this@MainActivity.filePathCallback = null
                    return false
                }
                filePickerLauncher.launch(intent)
                return true
            }
        }
    }

    private fun showEmailHint() {
        try {
            @Suppress("DEPRECATION")
            val intent = AccountManager.newChooseAccountIntent(
                null, null, arrayOf("com.google"),
                null, null, null, null
            )
            hintLauncher.launch(intent)
        } catch (_: Exception) {
            // No Google accounts or system unavailable — silent no-op
        }
    }

    private fun injectEmailWhenReady(email: String) {
        val safe = email.replace("\\", "\\\\").replace("\"", "\\\"")
        val js = """
            (function(email) {
                function fill() {
                    var el = document.getElementById('login-email');
                    if (!el) return false;
                    el.value = email;
                    el.dispatchEvent(new Event('input', {bubbles:true}));
                    return true;
                }
                if (fill()) return;
                var obs = new MutationObserver(function() {
                    if (fill()) obs.disconnect();
                });
                obs.observe(document.body, {childList:true, subtree:true});
            })("$safe");
        """.trimIndent()
        webView.evaluateJavascript(js, null)
    }

    private fun registerNetworkCallback() {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onLost(network: Network) {
                runOnUiThread {
                    swipeRefresh.visibility = View.GONE
                    offlineView.visibility = View.VISIBLE
                }
            }
            override fun onAvailable(network: Network) {
                runOnUiThread {
                    if (offlineView.visibility == View.VISIBLE) {
                        offlineView.visibility = View.GONE
                        swipeRefresh.visibility = View.VISIBLE
                        isPageLoaded = false
                        webView.reload()
                    }
                }
            }
        })
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.data?.toString()?.let { webView.loadUrl(it) }
    }

    companion object {
        private const val HOME_URL = "https://ai.myra.eu"
        private const val SPLASH_TIMEOUT_MS = 5_000L
    }

    inner class NativeBridge(private val ctx: MainActivity) {

        @JavascriptInterface
        fun hapticFeedback(type: String) {
            val effect = when (type) {
                "light"   -> VibrationEffect.createOneShot(30, 80)
                "medium"  -> VibrationEffect.createOneShot(50, 150)
                "success" -> VibrationEffect.createWaveform(
                    longArrayOf(0, 40, 30, 40), intArrayOf(0, 100, 0, 200), -1
                )
                else      -> VibrationEffect.createOneShot(30, 80)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                (ctx.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager)
                    .defaultVibrator.vibrate(effect)
            } else {
                @Suppress("DEPRECATION")
                (ctx.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator).vibrate(effect)
            }
        }

        @JavascriptInterface
        fun share(text: String, url: String) {
            val body = if (url.isNotEmpty()) "$text $url" else text
            ctx.startActivity(
                Intent.createChooser(
                    Intent(Intent.ACTION_SEND).apply {
                        this.type = "text/plain"
                        putExtra(Intent.EXTRA_TEXT, body)
                    }, "Share"
                )
            )
        }

        @JavascriptInterface
        @Suppress("UNUSED_PARAMETER")
        fun notifyScrollTop(scrolled: Boolean) {
            // Kept for web app compatibility. Pull-to-refresh guard now relies solely
            // on WebView.canScrollVertically(-1) which is more reliable.
        }

        @JavascriptInterface
        fun copyToClipboard(text: String) {
            (ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager)
                .setPrimaryClip(ClipData.newPlainText("", text))
        }
    }
}
