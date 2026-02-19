#!/usr/bin/env bash
set -euo pipefail

# --- Configuration (override via environment variables) ---
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-password}"
DASHBOARD_FILE="grafana_smokeping_dashboard.json"
DATASOURCE_UID="smokeping-prometheus"
DASHBOARD_UID="smokeping-dashboard"
REBUILD=false

# --- Parse flags ---
for arg in "$@"; do
  case "$arg" in
    --rebuild) REBUILD=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

# --- Check dependencies ---
for cmd in jq curl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is required but not installed."
    exit 1
  fi
done

# --- Read targets from environment ---
TARGETS_STR="${TARGETS:-1.1.1.1 8.8.8.8}"
read -ra TARGETS <<< "$TARGETS_STR"

if [ ${#TARGETS[@]} -eq 0 ]; then
  echo "Error: No ping targets specified. Set TARGETS env var (space-separated)."
  exit 1
fi

echo "Found ${#TARGETS[@]} target(s): ${TARGETS[*]}"

# --- Wait for Grafana to be ready ---
echo "Waiting for Grafana at $GRAFANA_URL ..."
MAX_RETRIES=30
for ((i=1; i<=MAX_RETRIES; i++)); do
  if curl -sf "$GRAFANA_URL/api/health" &>/dev/null; then
    break
  fi
  if [ "$i" -eq "$MAX_RETRIES" ]; then
    echo "Error: Grafana did not become ready within $MAX_RETRIES attempts."
    exit 1
  fi
  sleep 2
done
echo "Grafana is ready."

# Wait for the provisioned datasource to appear
echo "Waiting for datasource '$DATASOURCE_UID' ..."
for ((i=1; i<=MAX_RETRIES; i++)); do
  HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
    -u "$GRAFANA_USER:$GRAFANA_PASSWORD" \
    "$GRAFANA_URL/api/datasources/uid/$DATASOURCE_UID" 2>/dev/null || true)
  if [ "$HTTP_CODE" = "200" ]; then
    break
  fi
  if [ "$i" -eq "$MAX_RETRIES" ]; then
    echo "Error: Datasource '$DATASOURCE_UID' not found after $MAX_RETRIES attempts."
    echo "Make sure the provisioning volume is mounted in docker-compose.yml."
    exit 1
  fi
  sleep 2
done
echo "Datasource ready."

# --- Rebuild: backup existing dashboard ---
if $REBUILD; then
  echo "Rebuild mode: backing up existing dashboard ..."
  EXISTING=$(curl -sf -u "$GRAFANA_USER:$GRAFANA_PASSWORD" \
    "$GRAFANA_URL/api/dashboards/uid/$DASHBOARD_UID" 2>/dev/null || true)
  if [ -n "$EXISTING" ] && echo "$EXISTING" | jq -e '.dashboard' &>/dev/null; then
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    BACKUP_UID="smokeping-backup-${TIMESTAMP}"
    BACKUP_TITLE="SmokePing (backup ${TIMESTAMP})"

    echo "$EXISTING" | jq --arg uid "$BACKUP_UID" --arg title "$BACKUP_TITLE" '{
      dashboard: (.dashboard | .uid = $uid | .title = $title | del(.id) | .version = 1),
      overwrite: false
    }' | curl -sf -X POST \
      -H "Content-Type: application/json" \
      -u "$GRAFANA_USER:$GRAFANA_PASSWORD" \
      -d @- \
      "$GRAFANA_URL/api/dashboards/db" >/dev/null

    echo "Backup created: $BACKUP_TITLE (uid: $BACKUP_UID)"
  else
    echo "No existing dashboard to back up, skipping."
  fi
fi

# --- Generate dashboard JSON ---
echo "Generating dashboard ..."

# Build a JSON array of targets for jq
TARGETS_JSON=$(printf '%s\n' "${TARGETS[@]}" | jq -R . | jq -s .)

DASHBOARD_JSON=$(jq -n \
  --argjson targets "$TARGETS_JSON" \
  --arg ds_uid "$DATASOURCE_UID" \
  --arg dash_uid "$DASHBOARD_UID" \
'
def histogram_panel(ip; idx):
  {
    datasource: { type: "prometheus", uid: $ds_uid },
    description: ip,
    fieldConfig: {
      defaults: {
        color: { mode: "thresholds" },
        custom: {
          fillOpacity: 50,
          gradientMode: "scheme",
          hideFrom: { legend: false, tooltip: false, viz: false },
          lineWidth: 1
        },
        fieldMinMax: false,
        mappings: [],
        thresholds: {
          mode: "percentage",
          steps: [
            { color: "dark-orange", value: null },
            { color: "semi-dark-orange", value: 10 },
            { color: "orange", value: 20 },
            { color: "light-orange", value: 30 },
            { color: "super-light-orange", value: 40 },
            { color: "#ffffff", value: 50 }
          ]
        },
        unit: "none",
        unitScale: true
      },
      overrides: []
    },
    gridPos: { h: 16, w: 14, x: 0, y: (idx * 16) },
    id: (idx * 3 + 1),
    options: {
      bucketOffset: 0,
      combine: false,
      legend: {
        calcs: [],
        displayMode: "list",
        placement: "bottom",
        showLegend: (if idx == 0 then true else false end)
      }
    },
    pluginVersion: "10.3.3",
    targets: [
      {
        datasource: { type: "prometheus", uid: $ds_uid },
        editorMode: "code",
        exemplar: false,
        expr: ("sum(increase(smokeping_response_duration_seconds_bucket{ip=\"" + ip + "\"}[$__interval])) by (le)"),
        format: "heatmap",
        instant: false,
        legendFormat: "{{le}}",
        range: true,
        refId: "A"
      }
    ],
    title: ("SmokePing " + ip),
    type: "histogram"
  };

def heatmap_panel(ip; idx):
  {
    datasource: { type: "prometheus", uid: $ds_uid },
    description: ip,
    fieldConfig: {
      defaults: {
        custom: {
          hideFrom: { legend: false, tooltip: false, viz: false },
          scaleDistribution: { type: "linear" }
        },
        unitScale: true
      },
      overrides: []
    },
    gridPos: { h: 12, w: 7, x: 14, y: (idx * 16) },
    id: (idx * 3 + 2),
    interval: "10s",
    maxDataPoints: 100,
    options: {
      calculate: false,
      cellGap: 1,
      color: {
        exponent: 0.5,
        fill: "dark-orange",
        mode: "scheme",
        reverse: false,
        scale: "exponential",
        scheme: "Oranges",
        steps: 64
      },
      exemplars: { color: "rgba(255,0,255,0.7)" },
      filterValues: { le: 1e-9 },
      legend: { show: true },
      rowsFrame: { layout: "le" },
      tooltip: { mode: "single", showColorScale: false, yHistogram: false },
      yAxis: { axisPlacement: "left", reverse: false }
    },
    pluginVersion: "10.3.3",
    targets: [
      {
        datasource: { type: "prometheus", uid: $ds_uid },
        disableTextWrap: false,
        editorMode: "code",
        exemplar: false,
        expr: ("sum by(le) (increase(smokeping_response_duration_seconds_bucket{ip=\"" + ip + "\"}[$__interval]))"),
        format: "heatmap",
        fullMetaSearch: false,
        includeNullMetadata: true,
        instant: false,
        legendFormat: "{{le}}",
        range: true,
        refId: "A",
        useBackend: false
      }
    ],
    title: ("SmokePing " + ip),
    transformations: [],
    type: "heatmap"
  };

def barchart_panel(ip; idx):
  {
    datasource: { type: "prometheus", uid: $ds_uid },
    description: "",
    fieldConfig: {
      defaults: {
        color: { mode: "thresholds" },
        custom: {
          axisBorderShow: false,
          axisCenteredZero: false,
          axisColorMode: "text",
          axisLabel: "",
          axisPlacement: "auto",
          fillOpacity: 80,
          gradientMode: "none",
          hideFrom: { legend: false, tooltip: false, viz: false },
          lineWidth: 1,
          scaleDistribution: { type: "linear" },
          thresholdsStyle: { mode: "off" }
        },
        mappings: [],
        thresholds: {
          mode: "absolute",
          steps: [
            { color: "dark-red", value: null }
          ]
        },
        unitScale: true
      },
      overrides: []
    },
    gridPos: { h: 4, w: 7, x: 14, y: (idx * 16 + 12) },
    id: (idx * 3 + 3),
    maxDataPoints: 100,
    options: {
      barRadius: 0,
      barWidth: 0.97,
      colorByField: "Time",
      fullHighlight: false,
      groupWidth: 0.7,
      legend: {
        calcs: [],
        displayMode: "list",
        placement: "bottom",
        showLegend: false
      },
      orientation: "auto",
      showValue: "auto",
      stacking: "none",
      tooltip: { mode: "single", sort: "none" },
      xTickLabelRotation: 0,
      xTickLabelSpacing: 200
    },
    pluginVersion: "10.3.3",
    targets: [
      {
        datasource: { type: "prometheus", uid: $ds_uid },
        disableTextWrap: false,
        editorMode: "builder",
        expr: ("increase(smokeping_response_duration_seconds_count{ip=\"" + ip + "\"}[$__interval])"),
        fullMetaSearch: false,
        includeNullMetadata: true,
        instant: false,
        legendFormat: "__auto",
        range: true,
        refId: "Responses",
        useBackend: false
      },
      {
        datasource: { type: "prometheus", uid: $ds_uid },
        disableTextWrap: false,
        editorMode: "builder",
        expr: ("increase(smokeping_requests_total{ip=\"" + ip + "\"}[$__interval])"),
        fullMetaSearch: false,
        hide: false,
        includeNullMetadata: true,
        instant: false,
        legendFormat: "__auto",
        range: true,
        refId: "Requests",
        useBackend: false
      }
    ],
    title: ("Dropped pings " + ip),
    transformations: [
      {
        id: "calculateField",
        options: {
          binary: { left: "A", operator: "-", right: "B" },
          mode: "reduceRow",
          reduce: { include: [], reducer: "diff" },
          replaceFields: true
        }
      }
    ],
    type: "barchart"
  };

($targets | length) as $n |
{
  annotations: {
    list: [
      {
        builtIn: 1,
        datasource: { type: "grafana", uid: "-- Grafana --" },
        enable: true,
        hide: true,
        iconColor: "rgba(0, 211, 255, 1)",
        name: "Annotations & Alerts",
        type: "dashboard"
      }
    ]
  },
  editable: true,
  fiscalYearStartMonth: 0,
  graphTooltip: 0,
  links: [],
  liveNow: false,
  panels: (
    [ $targets | to_entries[] |
      histogram_panel(.value; .key),
      heatmap_panel(.value; .key),
      barchart_panel(.value; .key)
    ] + [
      {
        datasource: { type: "prometheus", uid: $ds_uid },
        description: "",
        fieldConfig: {
          defaults: {
            color: { mode: "thresholds" },
            mappings: [],
            thresholds: {
              mode: "absolute",
              steps: [
                { color: "green", value: null }
              ]
            },
            unitScale: true
          },
          overrides: []
        },
        gridPos: { h: ($n * 16 - 1), w: 2, x: 21, y: 0 },
        id: 1000,
        options: {
          colorMode: "value",
          graphMode: "area",
          justifyMode: "auto",
          orientation: "auto",
          reduceOptions: { calcs: ["lastNotNull"], fields: "", values: false },
          showPercentChange: false,
          textMode: "auto",
          wideLayout: true
        },
        pluginVersion: "10.3.3",
        targets: [
          {
            datasource: { type: "prometheus", uid: $ds_uid },
            editorMode: "code",
            expr: "smokeping_requests_total",
            instant: false,
            legendFormat: "{{ip}}",
            range: true,
            refId: "A"
          }
        ],
        title: "Requests",
        type: "stat"
      },
      {
        datasource: { type: "prometheus", uid: $ds_uid },
        fieldConfig: {
          defaults: {
            color: { mode: "thresholds" },
            mappings: [],
            thresholds: {
              mode: "absolute",
              steps: [
                { color: "green", value: null },
                { color: "red", value: 1 }
              ]
            },
            unitScale: true
          },
          overrides: []
        },
        gridPos: { h: ($n * 16 - 1), w: 1, x: 23, y: 0 },
        id: 1001,
        options: {
          colorMode: "value",
          graphMode: "area",
          justifyMode: "auto",
          orientation: "auto",
          reduceOptions: { calcs: ["lastNotNull"], fields: "", values: false },
          showPercentChange: false,
          textMode: "auto",
          wideLayout: true
        },
        pluginVersion: "10.3.3",
        targets: [
          {
            datasource: { type: "prometheus", uid: $ds_uid },
            editorMode: "code",
            expr: "smokeping_send_errors_total",
            instant: false,
            legendFormat: "{{ip}}",
            range: true,
            refId: "A"
          }
        ],
        title: "Errors",
        type: "stat"
      }
    ]
  ),
  refresh: false,
  schemaVersion: 39,
  tags: [],
  templating: { list: [] },
  time: { from: "now-24h", to: "now" },
  timepicker: {},
  timezone: "",
  title: "SmokePing",
  uid: $dash_uid,
  version: 1,
  weekStart: ""
}
')

# --- Write dashboard JSON to file ---
echo "$DASHBOARD_JSON" > "$DASHBOARD_FILE"
echo "Wrote $DASHBOARD_FILE"

# --- Import dashboard via Grafana API ---
echo "Importing dashboard to Grafana ..."
IMPORT_PAYLOAD=$(jq -n --argjson dash "$DASHBOARD_JSON" '{
  dashboard: $dash,
  overwrite: true
}')

RESPONSE=$(curl -sf -X POST \
  -H "Content-Type: application/json" \
  -u "$GRAFANA_USER:$GRAFANA_PASSWORD" \
  -d "$IMPORT_PAYLOAD" \
  "$GRAFANA_URL/api/dashboards/db")

DASH_URL=$(echo "$RESPONSE" | jq -r '.url // empty')
if [ -n "$DASH_URL" ]; then
  echo "Dashboard imported: ${GRAFANA_URL}${DASH_URL}"
else
  echo "Dashboard import response: $RESPONSE"
fi

echo "Done."
