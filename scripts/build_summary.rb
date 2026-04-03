# frozen_string_literal: true
# Usage: bundle exec ruby scripts/build_summary.rb
# raw_records テーブルから daily_summary / records / meta を構築する。
# import_xml.rb 実行後に呼ぶ。何度でも再実行可能（派生テーブルを再構築）。

require 'date'
require 'fileutils'
require 'sqlite3'
require 'time'

DB_PATH = ENV.fetch('HEALTH_DB_PATH', 'db/health.db').freeze

# --- 日次集計用定数 ---
SUM_METRICS  = %w[StepCount ActiveEnergyBurned].freeze
MEAN_METRICS = %w[HeartRate RestingHeartRate HRV RespiratoryRate].freeze
LAST_METRICS = %w[BodyMass VO2Max BodyFatPercentage].freeze

DERIVED_TABLES_DDL = [
  <<~SQL,
    CREATE TABLE IF NOT EXISTS records (
      id      INTEGER PRIMARY KEY,
      date    TEXT NOT NULL,
      metric  TEXT NOT NULL,
      value   REAL NOT NULL,
      unit    TEXT NOT NULL
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
  abort("DB が見つかりません: #{path}\nまず import_xml.rb を実行してください。") unless File.exist?(path)
  db = SQLite3::Database.new(path)
  db.results_as_hash = true
  db.execute('PRAGMA journal_mode=WAL')
  db.execute('PRAGMA synchronous=NORMAL')
  db.execute('PRAGMA cache_size=-65536')
  DERIVED_TABLES_DDL.each { |sql| db.execute(sql) }
  db
end

def clear_derived(db)
  %w[records daily_summary meta].each { |t| db.execute("DELETE FROM #{t}") }
  $stderr.puts '  派生テーブルをクリア'
end

# --- 日次集計: SUM系 ---
def aggregate_sum(db, metric)
  db.execute(<<~SQL, [metric]).each_with_object({}) { |r, h| h[r['date']] = { value: r['val'], unit: r['unit'] } }
    SELECT substr(start_date, 1, 10) AS date,
           SUM(CAST(value AS REAL))  AS val,
           MAX(unit)                 AS unit
    FROM raw_records
    WHERE metric = ? AND value != '' AND CAST(value AS REAL) > 0
    GROUP BY date
  SQL
end

# --- 日次集計: MEAN系 ---
def aggregate_mean(db, metric)
  db.execute(<<~SQL, [metric]).each_with_object({}) { |r, h| h[r['date']] = { value: r['val'], unit: r['unit'] } }
    SELECT substr(start_date, 1, 10) AS date,
           AVG(CAST(value AS REAL))  AS val,
           MAX(unit)                 AS unit
    FROM raw_records
    WHERE metric = ? AND CAST(value AS REAL) > 0
    GROUP BY date
  SQL
end

# --- 日次集計: 最終値系（体重・体脂肪・VO2Max） ---
def aggregate_last(db, metric)
  # start_date 降順で最後の値を取得
  daily = {}
  db.execute(<<~SQL, [metric]).each do |r|
    SELECT substr(start_date, 1, 10) AS date,
           CAST(value AS REAL)       AS val,
           unit,
           start_date
    FROM raw_records
    WHERE metric = ? AND CAST(value AS REAL) > 0
    ORDER BY start_date ASC
  SQL
    daily[r['date']] = { value: r['val'], unit: r['unit'] }
  end
  daily
end

# --- 日次集計: 睡眠（カテゴリ分割あり） ---
def aggregate_sleep(db)
  rows = db.execute(<<~SQL)
    SELECT start_date, end_date, value
    FROM raw_records
    WHERE metric = 'SleepAnalysis'
    ORDER BY start_date ASC
  SQL

  sleep_daily = Hash.new { |h, k| h[k] = { total_min: 0.0, asleep_min: 0.0 } }

  rows.each do |row|
    start_t = Time.parse(row['start_date']) rescue next
    end_t   = Time.parse(row['end_date'])   rescue next
    min     = (end_t - start_t) / 60.0
    next unless min > 0 && min < 1440  # 0〜24時間のサニティチェック
    date    = end_t.to_date.to_s
    sleep_daily[date][:total_min]  += min
    sleep_daily[date][:asleep_min] += min if row['value'].to_s.match?(/Asleep/)
  end

  sleep_daily
end

# --- ベースライン計算 ---
def compute_baselines(db)
  rhr_vals = db.execute(
    'SELECT CAST(value AS REAL) AS v FROM raw_records WHERE metric = ? AND CAST(value AS REAL) > 0',
    ['RestingHeartRate']
  ).map { |r| r['v'] }

  hrv_vals = db.execute(
    'SELECT CAST(value AS REAL) AS v FROM raw_records WHERE metric = ? AND CAST(value AS REAL) > 0',
    ['HRV']
  ).map { |r| r['v'] }

  rhr_p10  = rhr_vals.empty? ? 55.0 : rhr_vals.sort[rhr_vals.length / 10].round(1)
  hrv_mean = hrv_vals.empty? ? nil  : (hrv_vals.sum / hrv_vals.length.to_f).round(2)

  [rhr_p10, hrv_mean]
end

# --- 身体スコア ---
def body_battery(rhr, hrv, resp_rate, baseline_rhr, baseline_hrv)
  components = []
  if hrv && baseline_hrv && baseline_hrv > 0
    components << { score: [[hrv / baseline_hrv * 55, 0].max, 55].min, weight: 55 }
  end
  if rhr && baseline_rhr
    components << { score: [[30 - [rhr - baseline_rhr, 0].max * 1.875, 0].max, 30].min, weight: 30 }
  end
  if resp_rate
    components << { score: [[15 - (resp_rate - 14.0).abs * 2.25, 0].max, 15].min, weight: 15 }
  end
  return nil if components.empty?
  (components.sum { |c| c[:score] } * 100.0 / components.sum { |c| c[:weight] }).round
end

# --- records テーブルへ upsert ---
def insert_records(db, daily_map, metric, unit_fallback = '')
  stmt = db.prepare(<<~SQL)
    INSERT INTO records (date, metric, value, unit)
    VALUES (?, ?, ?, ?)
    ON CONFLICT(metric, date) DO UPDATE SET value=excluded.value, unit=excluded.unit
  SQL
  db.transaction do
    daily_map.each do |date, data|
      stmt.execute(date, metric, data[:value], data[:unit] || unit_fallback)
    end
  end
  stmt.close
  daily_map.size
end

# --- daily_summary テーブルを構築 ---
def build_daily_summary(db, all_metrics, sleep_daily, baseline_rhr, baseline_hrv)
  now  = Time.now.strftime('%Y-%m-%dT%H:%M:%S%z')
  stmt = db.prepare(<<~SQL)
    INSERT OR REPLACE INTO daily_summary
      (date, step_count, active_energy, body_mass, body_fat, heart_rate,
       resting_hr, hrv, respiratory_rate, vo2max, sleep_hours, asleep_hours,
       body_battery, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  SQL

  # 全メトリクスに登場する日付を統合
  all_dates = (all_metrics.values.flat_map(&:keys) + sleep_daily.keys).uniq.sort

  db.transaction do
    all_dates.each do |date|
      step          = all_metrics['StepCount']&.dig(date, :value)
      energy        = all_metrics['ActiveEnergyBurned']&.dig(date, :value)
      body_mass     = all_metrics['BodyMass']&.dig(date, :value)
      body_fat_raw  = all_metrics['BodyFatPercentage']&.dig(date, :value)
      # 体脂肪: Apple Health は 0〜1 の分数で保存している場合がある → %換算
      body_fat      = body_fat_raw ? (body_fat_raw < 1.0 ? (body_fat_raw * 100).round(2) : body_fat_raw.round(2)) : nil
      hr            = all_metrics['HeartRate']&.dig(date, :value)
      rhr           = all_metrics['RestingHeartRate']&.dig(date, :value)
      hrv           = all_metrics['HRV']&.dig(date, :value)
      resp          = all_metrics['RespiratoryRate']&.dig(date, :value)
      vo2max        = all_metrics['VO2Max']&.dig(date, :value)
      sleep_min     = sleep_daily[date]&.fetch(:total_min)
      asleep_min    = sleep_daily[date]&.fetch(:asleep_min)
      sleep_h       = sleep_min  ? (sleep_min  / 60.0).round(2) : nil
      asleep_h      = asleep_min ? (asleep_min / 60.0).round(2) : nil
      bb            = body_battery(rhr, hrv, resp, baseline_rhr, baseline_hrv)

      stmt.execute(date, step, energy, body_mass, body_fat,
                   hr, rhr, hrv, resp, vo2max,
                   sleep_h, asleep_h, bb, now)
    end
  end
  stmt.close
  all_dates.size
end

# ---- main ----

$stderr.puts "サマリー構築開始: #{DB_PATH}"
db = open_db(DB_PATH)
clear_derived(db)

$stderr.puts '日次集計中...'
all_metrics = {}
SUM_METRICS.each  { |m| all_metrics[m] = aggregate_sum(db, m);  $stderr.puts "  #{m}: #{all_metrics[m].size} 日" }
MEAN_METRICS.each { |m| all_metrics[m] = aggregate_mean(db, m); $stderr.puts "  #{m}: #{all_metrics[m].size} 日" }
LAST_METRICS.each { |m| all_metrics[m] = aggregate_last(db, m); $stderr.puts "  #{m}: #{all_metrics[m].size} 日" }

$stderr.puts '睡眠集計中（カテゴリ分割）...'
sleep_daily = aggregate_sleep(db)
$stderr.puts "  SleepAnalysis: #{sleep_daily.size} 日"

$stderr.puts 'ベースライン計算中...'
baseline_rhr, baseline_hrv = compute_baselines(db)
$stderr.puts "  安静時心拍 p10: #{baseline_rhr} bpm, HRV 平均: #{baseline_hrv} ms"

$stderr.puts 'records テーブルを構築中...'
total_records = 0
SUM_METRICS.each  { |m| total_records += insert_records(db, all_metrics[m], m) }
MEAN_METRICS.each { |m| total_records += insert_records(db, all_metrics[m], m) }
LAST_METRICS.each { |m| total_records += insert_records(db, all_metrics[m], m) }
sleep_daily.each do |date, data|
  db.execute(
    'INSERT INTO records (date, metric, value, unit) VALUES (?, ?, ?, ?) ON CONFLICT(metric, date) DO UPDATE SET value=excluded.value, unit=excluded.unit',
    [date, 'SleepAnalysis', data[:total_min], 'min']
  )
  db.execute(
    'INSERT INTO records (date, metric, value, unit) VALUES (?, ?, ?, ?) ON CONFLICT(metric, date) DO UPDATE SET value=excluded.value, unit=excluded.unit',
    [date, 'SleepAsleep', data[:asleep_min], 'min']
  )
  total_records += 2
end
$stderr.puts "  合計: #{total_records} 件"

$stderr.puts 'daily_summary を構築中...'
date_count = build_daily_summary(db, all_metrics, sleep_daily, baseline_rhr, baseline_hrv)

now = Time.now.strftime('%Y-%m-%dT%H:%M:%S%z')
{
  'baseline_rhr_p10'  => baseline_rhr.to_s,
  'baseline_hrv_mean' => baseline_hrv.to_s,
  'built_at'          => now,
  'record_count'      => total_records.to_s,
  'date_count'        => date_count.to_s,
}.each { |k, v| db.execute('INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)', [k, v]) }

db.close
$stderr.puts "完了: #{date_count} 日分の daily_summary を構築しました。"
$stderr.puts "次のステップ: bundle exec ruby scripts/analyze.rb"
