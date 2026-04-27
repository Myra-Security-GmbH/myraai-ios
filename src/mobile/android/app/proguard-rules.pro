# Keep @JavascriptInterface methods so the web app's window.Android.* bridge works after R8.
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
