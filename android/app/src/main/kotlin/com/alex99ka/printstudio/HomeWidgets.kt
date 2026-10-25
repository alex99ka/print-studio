package com.alex99ka.printstudio

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONObject

// Home screen widgets. The app writes their data (lib/core/home_widgets.dart)
// whenever it runs; a tap opens the app with printstudio://<action>.

private fun open(context: Context, action: String) =
    HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java, Uri.parse("printstudio://$action"))

/** How many items are open, and the first few. */
class SummaryWidget : HomeWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray, data: SharedPreferences) {
        val json = runCatching { JSONObject(data.getString("summary", null) ?: "{}") }.getOrDefault(JSONObject())
        val open = json.optInt("open", 0)
        val titles = json.optJSONArray("titles")
        val lines = if (titles == null) emptyList() else (0 until titles.length()).map { "• " + titles.getString(it) }
        for (id in ids) {
            val views = RemoteViews(context.packageName, R.layout.widget_summary).apply {
                setTextViewText(R.id.title, if (open == 0) "הכול בוצע" else "$open פתוחים")
                setTextViewText(R.id.body, lines.joinToString("\n"))
                setOnClickPendingIntent(R.id.root, open(context, "open"))
            }
            manager.updateAppWidget(id, views)
        }
    }
}

/** One tap to the quick-add field. */
class QuickAddWidget : HomeWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray, data: SharedPreferences) {
        for (id in ids) {
            val views = RemoteViews(context.packageName, R.layout.widget_quick_add).apply {
                setOnClickPendingIntent(R.id.root, open(context, "add"))
            }
            manager.updateAppWidget(id, views)
        }
    }
}
