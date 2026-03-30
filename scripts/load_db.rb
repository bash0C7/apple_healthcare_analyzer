# frozen_string_literal: true
# Usage: bundle exec ruby scripts/load_db.rb [output_dir]
# デフォルト: 増分upsert（既存DBに追記・更新）。
# 完全な再構築が必要な場合は db/health.db を手動で削除してから実行。

require 'csv'
require 'date'
require 'fileutils'
require 'sqlite3'
require 'time'

OUTPUT_DIR = 'output'.freeze
DB_PATH    = 'db/health.db'.freeze

METRICS = %w[
  StepCount BodyMass HeartRate RestingHeartRate ActiveEnergyBurned
  VO2Max BodyFatPercentage SleepAnalysis HRV RespiratoryRate
].freeze

SCHEMA_SQL = [
  <<~SQL,
    CREATE TABLE IF NOT EXISTS records (
      id      INTEGER PRIMARY KEY,
      date    TEXT    NOT NULL,
      metric  TEXT    NOT NULL,
      value   REAL    NOT NULL,
      unit    TEXT    NOT NULL
    )
  SQL
  'CREATE UNIQUE INDEX IF NOT EXISTS uix_records ON records (metric, date)',
  'CREATE INDEX IF NOT EXISTS ix_records_date ON records (date)',
  <<~SQL,
    CREATE TABLE IF NOT EXISTS daily_summary (
      date             TEXT    PRIMARY KEY,
      step_count       REAL,
      active_energy    REAL,
      body_mass        REAL,
      body_fat         REAL,
      heart_rate       REAL,
      resting_hr       REAL,
      hrv              REAL,
      respiratory_rate REAL,
      vo2max           REAL,
      sleep_hours      REAL,
      asleep_hours     REAL,
      body_battery     INTEGER,
      updated_at       TEXT    NOT NULL
    )
  SQL
  <<~SQL,
    CREATE TABLE IF NOT EXISTS meta (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  SQL
].freeze

def open_db(path)
  FileUtils.mkdir_p(File.dirname(path))
  db = SQLite3::Database.new(path)
  db.results_as_hash = true
  db.execute('PRAGMA journal_mode=WAL')
  db.execute('PRAGMA synchronous=NORMAL')
  SCHEMA_SQL.each { |sql| db.execute(sql) }
  db
end

def load_csv_rows(metric, output_dir)
  path = File.join(output_dir, "#{metric}.csv")
  unless File.exist?(path)
    $stderr.puts "WARN: #{path} not found, skipping"
    return []
  end
  CSV.read(path, headers: true)
rescue => e
  $stderr.puts "WARN: failed to read #{path}: #{e.message}"
  []
end

# SleepAnalysisはgrain形式によって異なる処理が必要。
# aggregated grain (unit='min'): valueが合計分数、カテゴリ分割不可
# full grain (unit=''): valueがカテゴリ文字列、startDate/endDateから時間を計算
def build_sleep_daily(rows)
  daily = Hash.new { |h, k| h[k] = { total_min: 0.0, asleep_min: 0.0 } }
  rows.each do |row|
    if row['unit'].to_s == 'min'
      date = row['startDate'].to_s.strip
      date = Date.parse(date).to_s rescue next
      min  = row['value'].to_f
      next if min <= 0
      daily[date][:total_min]  += min
      daily[date][:asleep_min] += min  # aggregated grain: カテゴリ分割不可
    else
      start_t = Time.parse(row['startDate'].to_s) rescue next
      end_t   = Time.parse(row['endDate'].to_s)   rescue next
      min     = (end_t - start_t) / 60.0
      next unless min > 0 && min < 1440
      date = end_t.to_date.to_s
      daily[date][:total_min]  += min
      daily[date][:asleep_min] += min if row['value'].to_s.match?(/Asleep/)
    end
  end
  daily
end

# 非スリープメトリクスをdateキーの値ハッシュに集約
def build_metric_daily(rows)
  daily = {}
  rows.each do |row|
    date  = row['startDate'].to_s.strip
    date  = Date.parse(date).to_s rescue next
    value = row['value'].to_f
    next if value <= 0 || value > 1_000_000
    daily[date] = value
  end
  daily
end

# 全CSVをインポートし、影響を受けたdate一覧を返す
def upsert_records(db, output_dir)
  stmt  = db.prepare('INSERT OR REPLACE INTO records (date, metric, value, unit) VALUES (?, ?, ?, ?)')
  dates = []
  total = 0

  db.transaction do
    (METRICS - ['SleepAnalysis']).each do |metric|
      rows  = load_csv_rows(metric, output_dir)
      daily = build_metric_daily(rows)
      daily.each do |date, value|
        unit = rows.find { |r| Date.parse(r['startDate'].to_s).to_s == date rescue false }&.fetch('unit', '') || ''
        stmt.execute(date, metric, value, unit)
        dates << date
      end
      $stderr.puts "  #{metric}: #{daily.size} 件"
      total += daily.size
    end

    # SleepAnalysisは別処理
    sleep_rows  = load_csv_rows('SleepAnalysis', output_dir)
    sleep_daily = build_sleep_daily(sleep_rows)
    sleep_daily.each do |date, data|
      stmt.execute(date, 'SleepAnalysis', data[:total_min], 'min')
      stmt.execute(date, 'SleepAsleep',   data[:asleep_min], 'min')
      dates << date
    end
    $stderr.puts "  SleepAnalysis: #{sleep_daily.size} 件"
    total += sleep_daily.size * 2
  end

  stmt.close
  [total, dates.uniq.sort]
end

def compute_baselines(db)
  rhr_vals = db.execute(
    'SELECT value FROM records WHERE metric = ? AND value > 0', ['RestingHeartRate']
  ).map { |r| r['value'] }

  hrv_vals = db.execute(
    'SELECT value FROM records WHERE metric = ? AND value > 0', ['HRV']
  ).map { |r| r['value'] }

  rhr_p10  = rhr_vals.empty? ? 55.0 : rhr_vals.sort[rhr_vals.length / 10]
  hrv_mean = hrv_vals.empty? ? nil  : (hrv_vals.sum / hrv_vals.length.to_f).round(2)

  [rhr_p10.round(1), hrv_mean]
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

# 指定dateの全メトリクスをrecordsから一括取得してdaily_summaryにupsert
def upsert_daily_summary(db, dates, baseline_rhr, baseline_hrv)
  return if dates.empty?

  now = Time.now.strftime('%Y-%m-%dT%H:%M:%S%z')

  # バッチ取得（SQLite variable limit対策）
  all_records = []
  dates.each_slice(900) do |batch|
    ph = (['?'] * batch.size).join(',')
    all_records.concat(db.execute("SELECT date, metric, value FROM records WHERE date IN (#{ph})", batch))
  end

  map = Hash.new { |h, k| h[k] = {} }
  all_records.each { |r| map[r['date']][r['metric']] = r['value'] }

  stmt = db.prepare(<<~SQL)
    INSERT OR REPLACE INTO daily_summary
      (date, step_count, active_energy, body_mass, body_fat, heart_rate,
       resting_hr, hrv, respiratory_rate, vo2max, sleep_hours, asleep_hours,
       body_battery, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  SQL

  db.transaction do
    dates.each do |date|
      m            = map[date]
      body_fat_raw = m['BodyFatPercentage']
      body_fat     = body_fat_raw ? (body_fat_raw < 1.0 ? (body_fat_raw * 100).round(2) : body_fat_raw.round(2)) : nil
      sleep_min    = m['SleepAnalysis']
      asleep_min   = m['SleepAsleep']
      sleep_h      = sleep_min   ? (sleep_min   / 60.0).round(2) : nil
      asleep_h     = asleep_min  ? (asleep_min  / 60.0).round(2) : nil
      rhr          = m['RestingHeartRate']
      hrv          = m['HRV']
      resp         = m['RespiratoryRate']
      bb           = body_battery(rhr, hrv, resp, baseline_rhr, baseline_hrv)

      stmt.execute(
        date, m['StepCount'], m['ActiveEnergyBurned'], m['BodyMass'], body_fat,
        m['HeartRate'], rhr, hrv, resp, m['VO2Max'],
        sleep_h, asleep_h, bb, now
      )
    end
  end
  stmt.close
end

def write_meta(db, baseline_rhr, baseline_hrv, record_count, date_count)
  now = Time.now.strftime('%Y-%m-%dT%H:%M:%S%z')
  {
    'baseline_rhr_p10'  => baseline_rhr.to_s,
    'baseline_hrv_mean' => baseline_hrv.to_s,
    'loaded_at'         => now,
    'record_count'      => record_count.to_s,
    'date_count'        => date_count.to_s,
  }.each do |k, v|
    db.execute('INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)', [k, v])
  end
end

# ---- main ----

output_dir = ARGV[0] || OUTPUT_DIR
$stderr.puts "ロード元: #{output_dir} → #{DB_PATH}"
$stderr.puts File.exist?(DB_PATH) ? 'モード: 増分upsert' : 'モード: 新規作成'

db = open_db(DB_PATH)

$stderr.puts 'records テーブルにupsert中...'
total_records, dates = upsert_records(db, output_dir)
$stderr.puts "合計: #{total_records} 件, #{dates.size} 日分"

$stderr.puts 'ベースライン計算中（DB全体）...'
baseline_rhr, baseline_hrv = compute_baselines(db)
$stderr.puts "  安静時心拍 p10: #{baseline_rhr}, HRV 平均: #{baseline_hrv}"

$stderr.puts "daily_summary を #{dates.size} 日分更新中..."
upsert_daily_summary(db, dates, baseline_rhr, baseline_hrv)

write_meta(db, baseline_rhr, baseline_hrv, total_records, dates.size)

db.close
$stderr.puts "完了。records: #{total_records} 件, dates: #{dates.size} 日分"
