# --- Observability: uptime checks, SLOs, alerts, dashboard -------------------

resource "google_monitoring_notification_channel" "email" {
  count        = var.alert_email == "" ? 0 : 1
  display_name = "LinkPulse on-call"
  type         = "email"
  labels       = { email_address = var.alert_email }
}

locals {
  channels = google_monitoring_notification_channel.email[*].id
}

# Uptime check per environment: hits /healthz from several regions every minute
resource "google_monitoring_uptime_check_config" "healthz" {
  for_each = google_cloud_run_v2_service.app

  display_name = "${each.value.name} /healthz"
  timeout      = "10s"
  period       = "60s"

  http_check {
    path         = "/healthz"
    port         = 443
    use_ssl      = true
    validate_ssl = true
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = trimprefix(each.value.uri, "https://")
    }
  }
}

resource "google_monitoring_alert_policy" "uptime" {
  for_each = google_monitoring_uptime_check_config.healthz

  display_name = "${each.key} is down"
  combiner     = "OR"
  conditions {
    display_name = "Uptime check failing"
    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.label.check_id=\"${each.value.uptime_check_id}\" AND resource.type=\"uptime_url\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = "120s"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.host"]
      }
    }
  }
  notification_channels = local.channels
}

# --- SLO: 99.5% of prod requests succeed (non-5xx) over 28 days ---------------

resource "google_monitoring_custom_service" "prod" {
  service_id   = "${var.app_name}-prod"
  display_name = "LinkPulse prod"
}

resource "google_monitoring_slo" "availability" {
  service      = google_monitoring_custom_service.prod.service_id
  slo_id       = "availability-99-5"
  display_name = "99.5% of requests are not 5xx"

  goal                = 0.995
  rolling_period_days = 28

  request_based_sli {
    good_total_ratio {
      total_service_filter = join(" AND ", [
        "metric.type=\"run.googleapis.com/request_count\"",
        "resource.type=\"cloud_run_revision\"",
        "resource.label.service_name=\"${var.app_name}-prod\"",
      ])
      bad_service_filter = join(" AND ", [
        "metric.type=\"run.googleapis.com/request_count\"",
        "resource.type=\"cloud_run_revision\"",
        "resource.label.service_name=\"${var.app_name}-prod\"",
        "metric.label.response_code_class=\"5xx\"",
      ])
    }
  }
}

# Burn-rate alert: page when the error budget burns 10x faster than allowed
resource "google_monitoring_alert_policy" "slo_burn" {
  display_name = "LinkPulse prod SLO fast burn"
  combiner     = "OR"
  conditions {
    display_name = "Error budget burn rate > 10x (1h)"
    condition_threshold {
      filter          = "select_slo_burn_rate(\"${google_monitoring_slo.availability.id}\", \"3600s\")"
      comparison      = "COMPARISON_GT"
      threshold_value = 10
      duration        = "0s"
    }
  }
  notification_channels = local.channels
}

# --- Dashboard ----------------------------------------------------------------

resource "google_monitoring_dashboard" "app" {
  dashboard_json = jsonencode({
    displayName = "LinkPulse"
    mosaicLayout = {
      columns = 12
      tiles = [
        for i, w in [
          { title = "Requests / s by status", metric = "run.googleapis.com/request_count", aligner = "ALIGN_RATE", group = ["metric.label.response_code_class"] },
          { title = "Latency p95 (ms)", metric = "run.googleapis.com/request_latencies", aligner = "ALIGN_PERCENTILE_95", group = ["resource.label.service_name"] },
          { title = "Instances", metric = "run.googleapis.com/container/instance_count", aligner = "ALIGN_MAX", group = ["resource.label.service_name"] },
          { title = "CPU utilisation", metric = "run.googleapis.com/container/cpu/utilizations", aligner = "ALIGN_PERCENTILE_95", group = ["resource.label.service_name"] },
          ] : {
          xPos   = (i % 2) * 6
          yPos   = floor(i / 2) * 4
          width  = 6
          height = 4
          widget = {
            title = w.title
            xyChart = {
              dataSets = [{
                plotType = "LINE"
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "metric.type=\"${w.metric}\" resource.type=\"cloud_run_revision\" resource.label.service_name=starts_with(\"${var.app_name}-\")"
                    aggregation = {
                      alignmentPeriod    = "60s"
                      perSeriesAligner   = w.aligner
                      crossSeriesReducer = w.aligner == "ALIGN_RATE" ? "REDUCE_SUM" : "REDUCE_MAX"
                      groupByFields      = w.group
                    }
                  }
                }
              }]
            }
          }
        }
      ]
    }
  })
}
