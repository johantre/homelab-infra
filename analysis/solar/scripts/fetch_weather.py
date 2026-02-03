#!/usr/bin/env python3
"""
Fetch historical weather data from Open-Meteo API.

Open-Meteo provides free historical weather data including:
- Temperature
- Cloud cover
- Solar radiation (GHI - Global Horizontal Irradiance)
- Precipitation

Usage:
    python fetch_weather.py --start 2025-07-01 --end 2026-02-01
"""

import argparse
import json
from datetime import datetime, timedelta
from pathlib import Path
import urllib.request
import urllib.parse

# Location: Home (from HA config)
LATITUDE = 50.78516
LONGITUDE = 3.91139

# Open-Meteo Historical API endpoint
API_URL = "https://archive-api.open-meteo.com/v1/archive"

# Output directory
DATA_DIR = Path(__file__).parent.parent / "data" / "weather"


def fetch_weather(start_date: str, end_date: str) -> dict:
    """Fetch historical weather data from Open-Meteo."""

    params = {
        "latitude": LATITUDE,
        "longitude": LONGITUDE,
        "start_date": start_date,
        "end_date": end_date,
        "daily": ",".join([
            "weather_code",
            "temperature_2m_max",
            "temperature_2m_min",
            "sunrise",
            "sunset",
            "daylight_duration",
            "sunshine_duration",
            "precipitation_sum",
            "rain_sum",
            "cloud_cover_mean",           # Average cloud cover %
            "shortwave_radiation_sum",    # Total solar radiation (MJ/m²)
        ]),
        "timezone": "Europe/Brussels"
    }

    url = f"{API_URL}?{urllib.parse.urlencode(params)}"
    print(f"Fetching weather data from {start_date} to {end_date}...")

    with urllib.request.urlopen(url) as response:
        data = json.loads(response.read().decode())

    return data


def save_weather(data: dict, filename: str):
    """Save weather data to JSON file."""
    output_path = DATA_DIR / filename
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    with open(output_path, "w") as f:
        json.dump(data, f, indent=2)

    print(f"Saved to {output_path}")


def main():
    parser = argparse.ArgumentParser(description="Fetch historical weather data")
    parser.add_argument("--start", default="2025-07-01", help="Start date (YYYY-MM-DD)")
    parser.add_argument("--end", default=datetime.now().strftime("%Y-%m-%d"), help="End date (YYYY-MM-DD)")
    args = parser.parse_args()

    # Fetch data
    data = fetch_weather(args.start, args.end)

    # Save to file
    filename = f"weather_{args.start}_{args.end}.json"
    save_weather(data, filename)

    # Print summary
    daily = data.get("daily", {})
    dates = daily.get("time", [])
    radiation = daily.get("shortwave_radiation_sum", [])
    cloud = daily.get("cloud_cover_mean", [])

    print(f"\nSummary:")
    print(f"  Days fetched: {len(dates)}")
    if radiation:
        avg_radiation = sum(r for r in radiation if r) / len([r for r in radiation if r])
        print(f"  Avg solar radiation: {avg_radiation:.1f} MJ/m²/day")
    if cloud:
        avg_cloud = sum(c for c in cloud if c) / len([c for c in cloud if c])
        print(f"  Avg cloud cover: {avg_cloud:.0f}%")


if __name__ == "__main__":
    main()
