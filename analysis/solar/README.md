# Solar Battery Analysis

Scripts and data for analysing solar energy production and battery behaviour.

## Goal

1. **Backtest**: Validate the decision algorithm against historical data
2. **Calibration**: Determine optimal threshold values
3. **Forecast validation**: Compare forecasts with actual production

## Folder Structure

```
analysis/solar/
├── data/                    # Raw data (not in git)
│   ├── solis_cloud/         # Exports from Solis Cloud
│   ├── ha_database/         # HA database exports
│   └── weather/             # Historical weather data (Open-Meteo)
├── scripts/                 # Analysis scripts
│   ├── backtest.py          # Backtest algorithm
│   ├── fetch_weather.py     # Fetch historical weather
│   └── validate_forecast.py # Forecast vs actual
└── README.md
```

## Data Sources

### 1. Solis Cloud Export

**Location**: `data/solis_cloud/`

**How to export**:
1. Login at [soliscloud.com](https://www.soliscloud.com)
2. Go to your installation > Station > Historical Data
3. Select period (July 2025 - present)
4. Export as CSV
5. Place files in `data/solis_cloud/`

**Expected files**:
- `daily_production_YYYY.csv` - Daily production
- `power_YYYYMM.csv` - Power per interval (optional, for detailed analysis)

### 2. Home Assistant Database

**Location**: `data/ha_database/`

**From production HA node**:
```bash
# Copy database from production node
scp root@192.168.3.8:/config/home-assistant_v2.db data/ha_database/
```

### 3. Historical Weather (Open-Meteo)

**Location**: `data/weather/`

Automatically fetched by `scripts/fetch_weather.py` via the free Open-Meteo Historical API.

## Running the Analysis

```bash
# 1. Fetch historical weather
python scripts/fetch_weather.py

# 2. Run backtest
python scripts/backtest.py

# 3. Validate forecast accuracy
python scripts/validate_forecast.py
```

## Parameters

See `../SOLAR_BATTERY_AUTOMATION.md` for full documentation of:
- Decision algorithm
- Success criteria (95% correct)
- Threshold values

## Data Privacy

The `data/` folder is in `.gitignore` - raw data is not committed.
