# frozen_string_literal: true
# Usage: bundle exec ruby scripts/analyze.rb [days=90]
#        bundle exec ruby scripts/analyze.rb YYYYMMDD YYYYMMDD
# Outputs JSON to stdout. Progress/errors to stderr.
#
# NOTE: CSVデータは月次集計 (startDate = "YYYY-MM" 形式)。
#       指定期間と重なる月のデータを取得し、月次サマリーを出力する。

require 'csv'
require 'date'
require 'json'
require 'time'

OUTPUT_DIR = 'output'.freeze

def parse_args(argv)
  if argv.length == 2
    from = Date.strptime(argv[0], '%Y%m%d')
    to   = Date.strptime(argv[1], '%Y%m%d')
  else
    days = (argv[0] || 90).to_i
    to   = Date.today
    from = to - days + 1
  end
  [from, to]
end

def load_csv(metric)
  path = File.join(OUTPUT_DIR, "#{metric}.csv")
  unless File.exist?(path)
    $stderr.puts "WARN: #{path} not found, skipping"
    return []
  end
  CSV.read(path, headers: true)
rescue => e
  $stderr.puts "WARN: failed to read #{path}: #{e.message}"
  []
end

# "YYYY-MM" => Date("YYYY-MM-01")、それ以外はDate.parse
def parse_month_key(str)
  return nil if str.nil? || str.empty?
  if str.match?(/\A\d{4}-\d{2}\z/)
    Date.parse("#{str}-01")
  else
    # 日付文字列から月初日を返す
    d = Date.parse(str)
    Date.new(d.year, d.month, 1)
  end
rescue ArgumentError
  nil
end

# 指定期間(from..to)と重なる月キーか判定
def month_in_range?(month_start, from, to)
  # month_start は月初日
  # 月末日 = 翌月初日 - 1
  month_end = (month_start >> 1) - 1
  month_start <= to && month_end >= from
end

# 月次データを { Date(月初日) => value } で返す（合計型）
def load_monthly_sum(metric, from, to)
  rows = load_csv(metric)
  result = {}
  rows.each do |row|
    ms = parse_month_key(row['startDate'])
    next unless ms && month_in_range?(ms, from, to)
    v = row['value'].to_f
    result[ms] = (result[ms] || 0.0) + v
  end
  result
end

# 月次データを { Date(月初日) => value } で返す（最終値型）
def load_monthly_last(metric, from, to)
  rows = load_csv(metric)
  result = {}
  rows.each do |row|
    ms = parse_month_key(row['startDate'])
    next unless ms && month_in_range?(ms, from, to)
    v = row['value'].to_f
    next if v <= 0 || v > 1_000_000
    result[ms] = v
  end
  result
end

# 月次データを { Date(月初日) => mean_value } で返す（平均型）
def load_monthly_mean(metric, from, to)
  rows = load_csv(metric)
  sums   = {}
  counts = {}
  rows.each do |row|
    ms = parse_month_key(row['startDate'])
    next unless ms && month_in_range?(ms, from, to)
    v = row['value'].to_f
    next if v <= 0
    sums[ms]   = (sums[ms]   || 0.0) + v
    counts[ms] = (counts[ms] || 0)   + 1
  end
  sums.each_with_object({}) { |(ms, s), h| h[ms] = s / counts[ms] }
end

# 睡眠は月次集計ではなくSleepAnalysisの個別レコードを集計
ASLEEP_PATTERN = /Asleep/.freeze

def load_monthly_sleep(from, to)
  rows = load_csv('SleepAnalysis')
  sleep_monthly  = {}
  asleep_monthly = {}
  rows.each do |row|
    end_t = Time.parse(row['endDate']) rescue next
    ed = Date.new(end_t.year, end_t.month, 1)
    next unless month_in_range?(ed, from, to)
    start_t = Time.parse(row['startDate']) rescue next
    hours = (end_t - start_t) / 3600.0
    next unless hours > 0 && hours < 24
    val = row['value'].to_s
    sleep_monthly[ed]  = (sleep_monthly[ed]  || 0.0) + hours
    asleep_monthly[ed] = (asleep_monthly[ed] || 0.0) + hours if ASLEEP_PATTERN.match?(val)
  end

  # 月あたりの平均睡眠時間（日数で割る）
  sleep_daily_avg  = {}
  asleep_daily_avg = {}
  sleep_monthly.each do |ms, total|
    # その月で実際にデータのある日数を概算（全体/31で割る代わりにdays_in_monthで）
    days = Date.new(ms.year, ms.month, -1).day
    sleep_daily_avg[ms]  = total / days
    asleep_daily_avg[ms] = (asleep_monthly[ms] || 0.0) / days
  end
  [sleep_daily_avg, asleep_daily_avg]
end

# Compute baseline RHR (10th percentile over full dataset)
def baseline_rhr_p10
  rows = load_csv('RestingHeartRate')
  values = rows.filter_map { |r| v = r['value'].to_f; v > 0 ? v : nil }
  return 55.0 if values.empty?
  values.sort[values.length / 10]
end

# Compute mean HRV over all available data (global baseline)
def baseline_hrv_mean
  rows = load_csv('HRV')
  values = rows.filter_map { |r| v = r['value'].to_f; v > 0 ? v : nil }
  return nil if values.empty?
  (values.sum / values.length.to_f).round(2)
end

# 全HRVデータを月次で返す（トレンド分析用）
def load_all_monthly_hrv
  rows = load_csv('HRV')
  result = {}
  rows.each do |row|
    ms = parse_month_key(row['startDate'])
    next unless ms
    v = row['value'].to_f
    next if v <= 0
    result[ms] = v
  end
  result.sort.to_h
end

def body_battery(rhr, hrv, resp_rate, baseline_rhr, baseline_hrv)
  components = []

  if hrv && baseline_hrv && baseline_hrv > 0
    components << { score: [[hrv / baseline_hrv * 55, 0].max, 55].min, weight: 55 }
  end

  if rhr && baseline_rhr
    components << { score: [[30 - [rhr - baseline_rhr, 0].max * 1.875, 0].max, 30].min, weight: 30 }
  end

  if resp_rate
    dev = (resp_rate - 14.0).abs
    components << { score: [[15 - dev * 2.25, 0].max, 15].min, weight: 15 }
  end

  return nil if components.empty?

  total_weight = components.sum { |c| c[:weight] }
  raw_score    = components.sum { |c| c[:score] }
  (raw_score * 100.0 / total_weight).round
end

def mean_of(arr)
  valid = arr.compact
  return nil if valid.empty?
  (valid.sum / valid.length.to_f).round(2)
end

# 指定期間をカバーする月のリストを返す
def months_in_range(from, to)
  months = []
  ms = Date.new(from.year, from.month, 1)
  while ms <= to
    months << ms
    ms = ms >> 1
  end
  months
end

from, to = parse_args(ARGV)
$stderr.puts "Analyzing #{from} to #{to}..."

baseline_rhr = baseline_rhr_p10
baseline_hrv = baseline_hrv_mean

steps   = load_monthly_sum('StepCount',          from, to)
energy  = load_monthly_sum('ActiveEnergyBurned', from, to)
sleep_avg, asleep_avg = load_monthly_sleep(from, to)
rhr     = load_monthly_mean('RestingHeartRate',  from, to)
hrv     = load_monthly_mean('HRV',               from, to)
resp    = load_monthly_mean('RespiratoryRate',    from, to)
mass    = load_monthly_last('BodyMass',           from, to)
fat     = load_monthly_last('BodyFatPercentage',  from, to)
vo2     = load_monthly_last('VO2Max',             from, to)

# Fix BodyFatPercentage: convert 0-1 fraction to percentage if needed
fat = fat.transform_values { |v| v < 1.0 ? (v * 100).round(2) : v.round(2) } unless fat.empty?

target_months = months_in_range(from, to)

monthly = target_months.map do |ms|
  month_label = ms.strftime('%Y-%m')
  bb = body_battery(rhr[ms], hrv[ms], resp[ms], baseline_rhr, baseline_hrv)
  {
    'month'            => month_label,
    'step_count_total' => steps[ms]&.round(0),
    'body_mass'        => mass[ms]&.round(2),
    'resting_hr'       => rhr[ms]&.round(1),
    'hrv'              => hrv[ms]&.round(1),
    'active_energy_total' => energy[ms]&.round(1),
    'sleep_hours_daily_avg'  => sleep_avg[ms]&.round(2),
    'asleep_hours_daily_avg' => asleep_avg[ms]&.round(2),
    'respiratory_rate' => resp[ms]&.round(2),
    'body_fat'         => fat[ms],
    'vo2max'           => vo2[ms]&.round(2),
    'body_battery'     => bb,
  }
end

# Summary: 対象月の集計
hrv_vals  = hrv.values
rhr_vals  = rhr.values
mass_vals = mass.values
resp_vals = resp.values
vo2_vals  = vo2.values

# 最新月のデータ
latest_month = target_months.max
prev_months  = target_months.sort

# 直近3ヶ月平均（トレンド用）
recent3 = prev_months.last(3)

summary = {
  'months_covered'     => target_months.length,
  'step_count'         => {
    'monthly_total'        => steps[latest_month]&.round(0),
    'daily_avg_this_month' => steps[latest_month] ? (steps[latest_month] / Date.new(latest_month.year, latest_month.month, -1).day).round(0) : nil,
  },
  'body_mass'          => {
    'latest'  => (mass[latest_month] || mass.max_by { |d, _| d }&.last)&.round(2),
    'mean_period' => mean_of(mass_vals),
  },
  'resting_heart_rate' => {
    'latest'      => (rhr[latest_month] || rhr.max_by { |d, _| d }&.last)&.round(1),
    'mean_period' => mean_of(rhr_vals),
    'min_period'  => rhr_vals.min&.round(1),
  },
  'hrv'                => {
    'latest'       => (hrv[latest_month] || hrv.max_by { |d, _| d }&.last)&.round(1),
    'mean_period'  => mean_of(hrv_vals),
    'recent3m_mean' => mean_of(recent3.filter_map { |ms| hrv[ms] }),
  },
  'respiratory_rate'   => {
    'latest'      => (resp[latest_month] || resp.max_by { |d, _| d }&.last)&.round(2),
    'mean_period' => mean_of(resp_vals),
  },
  'vo2max'             => {
    'latest'      => (vo2[latest_month] || vo2.max_by { |d, _| d }&.last)&.round(2),
  },
  'body_fat'           => {
    'latest'      => (fat[latest_month] || fat.max_by { |d, _| d }&.last),
  },
  'sleep_hours_daily_avg' => {
    'latest'      => sleep_avg[latest_month]&.round(2),
    'mean_period' => mean_of(sleep_avg.values),
  },
  'body_battery'       => {
    'latest' => body_battery(
      rhr[latest_month] || rhr.max_by { |d, _| d }&.last,
      hrv[latest_month] || hrv.max_by { |d, _| d }&.last,
      resp[latest_month] || resp.max_by { |d, _| d }&.last,
      baseline_rhr, baseline_hrv
    ),
  },
}

result = {
  'generated_at' => Date.today.to_s,
  'period'       => { 'from' => from.to_s, 'to' => to.to_s, 'days' => (to - from + 1).to_i },
  'baseline'     => { 'resting_hr_p10' => baseline_rhr.round(1), 'hrv_mean' => baseline_hrv },
  'summary'      => summary,
  'monthly'      => monthly,
}

puts JSON.pretty_generate(result)
