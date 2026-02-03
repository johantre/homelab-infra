#!/usr/bin/env python3
"""
Backtest the solar battery charging algorithm against historical data.

This script:
1. Loads historical PV production data (from Solis Cloud export)
2. Loads historical weather data (from Open-Meteo)
3. Simulates what decisions the algorithm would have made
4. Calculates accuracy against actual outcomes

Usage:
    python backtest.py
"""

import csv
import json
from datetime import datetime
from pathlib import Path
from dataclasses import dataclass
from typing import Optional

# Paths
DATA_DIR = Path(__file__).parent.parent / "data"
SOLIS_DIR = DATA_DIR / "solis_cloud"
WEATHER_DIR = DATA_DIR / "weather"

# Algorithm parameters (from SOLAR_BATTERY_AUTOMATION.md)
BATTERY_CAPACITY_KWH = 15.36
SAFETY_FACTOR = 0.8
THRESHOLD_KWH = BATTERY_CAPACITY_KWH * SAFETY_FACTOR  # 12.29 kWh


@dataclass
class DayData:
    """Data for a single day."""
    date: str
    actual_production_kwh: float
    forecast_kwh: Optional[float] = None  # From forecast service (simulated from weather)
    solar_radiation_mj: Optional[float] = None
    cloud_cover_pct: Optional[float] = None
    sunshine_hours: Optional[float] = None

    @property
    def algorithm_decision(self) -> str:
        """What would the algorithm decide based on forecast?"""
        # For backtest, we simulate forecast using solar radiation
        # In production, this would come from Forecast.Solar
        if self.forecast_kwh is None:
            return "unknown"
        return "charge" if self.forecast_kwh < THRESHOLD_KWH else "no_charge"

    @property
    def optimal_decision(self) -> str:
        """What should the decision have been based on actual production?"""
        return "charge" if self.actual_production_kwh < THRESHOLD_KWH else "no_charge"

    @property
    def decision_correct(self) -> bool:
        """Was the algorithm's decision correct?"""
        return self.algorithm_decision == self.optimal_decision


def load_solis_data(filepath: Path) -> dict[str, float]:
    """
    Load daily production data from Solis Cloud CSV export.

    Expected CSV format (adjust as needed based on actual export):
    Date,Daily Production (kWh),...
    """
    data = {}

    if not filepath.exists():
        print(f"Warning: Solis data file not found: {filepath}")
        return data

    with open(filepath, "r") as f:
        reader = csv.DictReader(f)
        for row in reader:
            # Adjust column names based on actual Solis Cloud export format
            date = row.get("Date") or row.get("date") or row.get("Time")
            production = row.get("Daily Production (kWh)") or row.get("production") or row.get("Energy(kWh)")

            if date and production:
                try:
                    data[date] = float(production)
                except ValueError:
                    pass

    return data


def load_weather_data(filepath: Path) -> dict[str, dict]:
    """Load weather data from Open-Meteo JSON export."""
    if not filepath.exists():
        print(f"Warning: Weather data file not found: {filepath}")
        return {}

    with open(filepath, "r") as f:
        data = json.load(f)

    daily = data.get("daily", {})
    dates = daily.get("time", [])

    result = {}
    for i, date in enumerate(dates):
        result[date] = {
            "solar_radiation_mj": daily.get("shortwave_radiation_sum", [None])[i],
            "cloud_cover_pct": daily.get("cloud_cover_mean", [None])[i],
            "sunshine_hours": (daily.get("sunshine_duration", [None])[i] or 0) / 3600,  # seconds to hours
        }

    return result


def estimate_forecast_from_weather(solar_radiation_mj: float, pv_capacity_kwp: float = 7.04) -> float:
    """
    Estimate PV production from solar radiation.

    This is a simplified model. In production, use Forecast.Solar for better accuracy.

    Approximate conversion:
    - Solar radiation in MJ/m² per day
    - 1 MJ = 0.2778 kWh
    - Typical panel efficiency ~18%
    - System losses ~15%
    """
    if solar_radiation_mj is None:
        return 0.0

    # Convert MJ/m² to kWh/m²
    kwh_per_m2 = solar_radiation_mj * 0.2778

    # Approximate: 1 kWp needs ~5-6 m² of panels
    # With ~18% efficiency and 15% system losses
    estimated_kwh = kwh_per_m2 * pv_capacity_kwp * 0.15  # Simplified factor

    return estimated_kwh


def run_backtest(solis_file: Path, weather_file: Path) -> list[DayData]:
    """Run backtest analysis."""
    solis_data = load_solis_data(solis_file)
    weather_data = load_weather_data(weather_file)

    if not solis_data:
        print("No Solis data loaded. Please export data from Solis Cloud.")
        print(f"Expected location: {solis_file}")
        return []

    results = []
    for date, production in solis_data.items():
        weather = weather_data.get(date, {})

        # Estimate forecast from weather (in production, use real forecast)
        forecast = estimate_forecast_from_weather(
            weather.get("solar_radiation_mj"),
        )

        day = DayData(
            date=date,
            actual_production_kwh=production,
            forecast_kwh=forecast if weather else None,
            solar_radiation_mj=weather.get("solar_radiation_mj"),
            cloud_cover_pct=weather.get("cloud_cover_pct"),
            sunshine_hours=weather.get("sunshine_hours"),
        )
        results.append(day)

    return results


def print_results(results: list[DayData]):
    """Print backtest results."""
    if not results:
        return

    # Filter days with valid forecasts
    valid = [r for r in results if r.forecast_kwh is not None]

    if not valid:
        print("No days with valid forecast data.")
        return

    correct = sum(1 for r in valid if r.decision_correct)
    total = len(valid)
    accuracy = (correct / total) * 100 if total > 0 else 0

    print(f"\n{'='*60}")
    print(f"BACKTEST RESULTS")
    print(f"{'='*60}")
    print(f"Period: {valid[0].date} to {valid[-1].date}")
    print(f"Days analyzed: {total}")
    print(f"Threshold: {THRESHOLD_KWH:.2f} kWh (battery {BATTERY_CAPACITY_KWH} × {SAFETY_FACTOR})")
    print(f"\nAccuracy: {accuracy:.1f}% ({correct}/{total} correct)")
    print(f"Target: 95%")
    print(f"{'='*60}")

    # Breakdown
    charge_correct = sum(1 for r in valid if r.optimal_decision == "charge" and r.decision_correct)
    charge_total = sum(1 for r in valid if r.optimal_decision == "charge")
    no_charge_correct = sum(1 for r in valid if r.optimal_decision == "no_charge" and r.decision_correct)
    no_charge_total = sum(1 for r in valid if r.optimal_decision == "no_charge")

    print(f"\nBreakdown:")
    if charge_total:
        print(f"  'Should charge' days: {charge_correct}/{charge_total} correct ({100*charge_correct/charge_total:.0f}%)")
    if no_charge_total:
        print(f"  'Should not charge' days: {no_charge_correct}/{no_charge_total} correct ({100*no_charge_correct/no_charge_total:.0f}%)")

    # Show some examples of incorrect decisions
    incorrect = [r for r in valid if not r.decision_correct][:5]
    if incorrect:
        print(f"\nSample incorrect decisions:")
        for r in incorrect:
            print(f"  {r.date}: forecast={r.forecast_kwh:.1f} kWh, actual={r.actual_production_kwh:.1f} kWh")
            print(f"           algorithm said '{r.algorithm_decision}', should have been '{r.optimal_decision}'")


def main():
    print("Solar Battery Algorithm Backtest")
    print("-" * 40)

    # Find data files
    solis_files = list(SOLIS_DIR.glob("*.csv"))
    weather_files = list(WEATHER_DIR.glob("*.json"))

    if not solis_files:
        print(f"\nNo Solis Cloud data found in {SOLIS_DIR}")
        print("Please export your data from soliscloud.com and place CSV files there.")
        return

    if not weather_files:
        print(f"\nNo weather data found in {WEATHER_DIR}")
        print("Run: python fetch_weather.py --start 2025-07-01")
        return

    # Use most recent files
    solis_file = sorted(solis_files)[-1]
    weather_file = sorted(weather_files)[-1]

    print(f"Using Solis data: {solis_file.name}")
    print(f"Using weather data: {weather_file.name}")

    results = run_backtest(solis_file, weather_file)
    print_results(results)


if __name__ == "__main__":
    main()
