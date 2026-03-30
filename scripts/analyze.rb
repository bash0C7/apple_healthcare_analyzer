# frozen_string_literal: true

require 'csv'
require 'date'
require 'json'

OUTPUT_DIR = 'output'.freeze

CSV_FILES = {
  step_count:         'StepCount.csv',
  body_mass:          'BodyMass.csv',
  resting_heart_rate: 'RestingHeartRate.csv',
  active_energy:      'ActiveEnergyBurned.csv',
  vo2max:             'VO2Max.csv',
  body_fat:           'BodyFatPercentage.csv',
  sleep:              'SleepAnalysis.csv'
}.freeze

def parse_args(argv)
  today = Date.today
  case argv.length
  when 0
    [today - 89, today]
  when 1
    days = argv[0].to_i
    [today - (days - 1), today]
  when 2
    [Date.strptime(argv[0], '%Y%m%d'), Date.strptime(argv[1], '%Y%m%d')]
  else
    abort('Usage: analyze.rb [days | from_yyyymmdd to_yyyymmdd]')
  end
end

def load_csv(metric)
  path = File.join(OUTPUT_DIR, CSV_FILES[metric])
  unless File.exist?(path)
    $stderr.puts "WARN: missing #{path}, skipping"
    return {}
  end
  rows = {}
  CSV.foreach(path, headers: true) do |row|
    month_key = row['startDate'].to_s.strip
    rows[month_key] = row
  end
  rows
rescue => e
  $stderr.puts "WARN: failed to read #{path}: #{e.message}"
  {}
end

def days_in_month(month_key)
  year, mon = month_key.split('-').map(&:to_i)
  Date.new(year, mon, -1).day
end

def month_in_range?(month_key, from_date, to_date)
  year, mon = month_key.split('-').map(&:to_i)
  month_start = Date.new(year, mon, 1)
  month_end   = Date.new(year, mon, -1)
  month_end >= from_date && month_start <= to_date
end

VO2MAX_MAX = 100.0   # ml/min/kg — filter out corrupted aggregated values
SAFE_FLOAT_MAX = 1_000_000.0

def safe_float(val, max: SAFE_FLOAT_MAX)
  return nil if val.nil?
  return nil if val.to_s.match?(/\A\s*[-+]?Inf/i)
  f = val.to_f
  return nil if f.infinite? || f.nan? || f > max
  f
end

def compute_rhr_p10_all
  path = File.join(OUTPUT_DIR, CSV_FILES[:resting_heart_rate])
  unless File.exist?(path)
    $stderr.puts "WARN: missing #{path} for baseline"
    return nil
  end
  vals = []
  CSV.foreach(path, headers: true) do |row|
    v = safe_float(row['value'])
    vals << v if v
  end
  return nil if vals.empty?
  sorted = vals.sort
  idx = [(sorted.length * 0.1).floor - 1, 0].max
  sorted[idx].round(1)
end

def build_months(from_date, to_date)
  months = []
  year, mon = from_date.year, from_date.month
  loop do
    key = format('%04d-%02d', year, mon)
    months << key
    break if year == to_date.year && mon == to_date.month
    mon += 1
    if mon > 12
      mon = 1
      year += 1
    end
  end
  months
end

def row_value(rows, month_key, divisor: 1, max: SAFE_FLOAT_MAX)
  row = rows[month_key]
  return nil unless row
  v = safe_float(row['value'], max: max)
  return nil unless v
  (v / divisor).round(4)
end

def build_daily_entry(month_key, data_map, baseline_rhr)
  days = days_in_month(month_key)
  steps        = row_value(data_map[:step_count],         month_key, divisor: days)
  body_mass    = row_value(data_map[:body_mass],          month_key)
  resting_hr   = row_value(data_map[:resting_heart_rate], month_key)
  active_kcal  = row_value(data_map[:active_energy],      month_key, divisor: days)
  sleep_min    = row_value(data_map[:sleep],              month_key)
  sleep_hours  = sleep_min ? (sleep_min / days / 60.0).round(2) : nil
  body_fat_raw = row_value(data_map[:body_fat],           month_key)
  body_fat     = body_fat_raw ? (body_fat_raw * 100).round(2) : nil
  vo2          = row_value(data_map[:vo2max],             month_key, max: VO2MAX_MAX)

  battery = body_battery(sleep_hours, resting_hr, active_kcal, baseline_rhr)

  {
    'date'          => month_key,
    'step_count'    => steps,
    'body_mass'     => body_mass,
    'resting_hr'    => resting_hr,
    'active_energy' => active_kcal,
    'sleep_hours'   => sleep_hours,
    'body_fat'      => body_fat,
    'vo2max'        => vo2,
    'body_battery'  => battery
  }
end

def clamp(val, min, max)
  [[val, min].max, max].min
end

def body_battery(sleep_hours, resting_hr, active_kcal, baseline_rhr)
  components = []
  components << clamp(sleep_hours / 7.5 * 40, 0, 40)   if sleep_hours
  components << clamp(40 - [resting_hr - baseline_rhr, 0].max * 2.5, 0, 40) if resting_hr && baseline_rhr
  components << clamp(active_kcal / 600.0 * 20, 0, 20) if active_kcal
  return nil if components.empty?
  present = components.length
  total   = components.sum
  total   = total * 3.0 / present if present < 3
  total.round
end

def mean(arr)
  return nil if arr.empty?
  (arr.sum / arr.length.to_f).round(2)
end

def build_summary(daily_entries, data_map, from_date, to_date)
  steps   = daily_entries.filter_map { |d| d['step_count'] }
  masses  = daily_entries.filter_map { |d| d['body_mass'] }
  rhrs    = daily_entries.filter_map { |d| d['resting_hr'] }
  energy  = daily_entries.filter_map { |d| d['active_energy'] }
  sleeps  = daily_entries.filter_map { |d| d['sleep_hours'] }
  fats    = daily_entries.filter_map { |d| d['body_fat'] }
  vo2s    = daily_entries.filter_map { |d| d['vo2max'] }

  recent = daily_entries.last(7)
  r_steps  = recent.filter_map { |d| d['step_count'] }
  r_energy = recent.filter_map { |d| d['active_energy'] }
  r_sleeps = recent.filter_map { |d| d['sleep_hours'] }

  {
    'step_count'         => { 'mean' => mean(steps),  'max' => steps.max&.round(2), 'min' => steps.min&.round(2), 'recent_7d_mean' => mean(r_steps) },
    'body_mass'          => { 'mean' => mean(masses),  'latest' => masses.last },
    'resting_heart_rate' => { 'mean' => mean(rhrs),    'min' => rhrs.min&.round(2),  'latest' => rhrs.last },
    'active_energy'      => { 'mean' => mean(energy),  'recent_7d_mean' => mean(r_energy) },
    'sleep_hours'        => { 'mean' => mean(sleeps),  'recent_7d_mean' => mean(r_sleeps) },
    'body_fat'           => { 'latest' => fats.last },
    'vo2max'             => { 'latest' => vo2s.last }
  }
end

from_date, to_date = parse_args(ARGV)
$stderr.puts "Period: #{from_date} to #{to_date}"

baseline_rhr = compute_rhr_p10_all
$stderr.puts "Baseline RHR p10: #{baseline_rhr}"

data_map = CSV_FILES.keys.each_with_object({}) do |metric, h|
  h[metric] = load_csv(metric)
end

months = build_months(from_date, to_date)
$stderr.puts "Months in range: #{months.length}"

daily_entries = months
  .select { |m| month_in_range?(m, from_date, to_date) }
  .map    { |m| build_daily_entry(m, data_map, baseline_rhr) }
  .sort_by { |d| d['date'] }

summary = build_summary(daily_entries, data_map, from_date, to_date)

output = {
  'generated_at' => Date.today.to_s,
  'period'       => { 'from' => from_date.to_s, 'to' => to_date.to_s, 'days' => (to_date - from_date).to_i + 1 },
  'baseline'     => { 'resting_hr_p10' => baseline_rhr },
  'summary'      => summary,
  'daily'        => daily_entries
}

puts JSON.generate(output)
