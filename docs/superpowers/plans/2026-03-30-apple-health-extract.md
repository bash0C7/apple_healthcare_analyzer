# Apple Health Extract — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 3GBのApple Health export.xmlからox SAXパーサで8種類の指標を抽出し、期間・粒度フィルタ付きCSVに書き出す。

**Architecture:** ox gem のSAXパーサで逐次処理（メモリ固定）。SaxHandlerクラスが属性収集・フィルタリング・集約バッファ管理を担い、flush_writersで一括CSV出力する。期間・粒度は引数で指定。

**Tech Stack:** Ruby 4.0.1, ox gem (SAX), csv/date/time/fileutils (stdlib)

---

### Task 1: プロジェクトセットアップ

**Files:**
- Create: `Gemfile`
- Create: `scripts/` `data/` `output/` (dirs)

- [ ] **Step 1: Gemfile 作成**

```ruby
# frozen_string_literal: true
source "https://rubygems.org"
gem "ox"
```

- [ ] **Step 2: ディレクトリ作成**

```bash
mkdir -p scripts data output
```

- [ ] **Step 3: bundle install**

```bash
bundle install
```

Expected output: `Bundle complete! 1 Gemfile dependency, N gems now installed.`

- [ ] **Step 4: ox が使えることを確認**

```bash
bundle exec ruby -e "require 'ox'; puts Ox::VERSION"
```

Expected: バージョン番号が表示される（例: `2.14.x`）

- [ ] **Step 5: commit**

```bash
git add Gemfile Gemfile.lock
git commit -m "chore: add Gemfile with ox gem"
```

---

### Task 2: gen_sample.rb — export.xml から sample.xml を生成

**Files:**
- Create: `scripts/gen_sample.rb`

- [ ] **Step 1: gen_sample.rb を作成**

```ruby
# frozen_string_literal: true
# Usage: bundle exec ruby scripts/gen_sample.rb export.xml

SAMPLE_TYPES = %w[
  HKQuantityTypeIdentifierStepCount
  HKQuantityTypeIdentifierBodyMass
  HKQuantityTypeIdentifierHeartRate
  HKQuantityTypeIdentifierRestingHeartRate
  HKQuantityTypeIdentifierActiveEnergyBurned
  HKQuantityTypeIdentifierVO2Max
  HKQuantityTypeIdentifierBodyFatPercentage
  HKCategoryTypeIdentifierSleepAnalysis
].freeze

RECORDS_PER_TYPE = 10

def collect_records(xml_path)
  counts  = Hash.new(0)
  records = []

  File.foreach(xml_path) do |line|
    next unless line.include?('<Record ')

    SAMPLE_TYPES.each do |type|
      if line.include?(%(type="#{type}")) && counts[type] < RECORDS_PER_TYPE
        records << line.chomp
        counts[type] += 1
        break
      end
    end

    break if SAMPLE_TYPES.all? { |t| counts[t] >= RECORDS_PER_TYPE }
  end

  warn_missing(counts)
  records
end

def warn_missing(counts)
  SAMPLE_TYPES.each do |type|
    n = counts[type]
    $stderr.puts "WARN: #{type} only #{n} records found" if n < RECORDS_PER_TYPE
  end
end

def write_sample_xml(records, output_path)
  File.open(output_path, 'w', encoding: 'UTF-8') do |f|
    f.puts '<?xml version="1.0" encoding="UTF-8"?>'
    f.puts '<HealthData locale="en_US">'
    records.each { |r| f.puts "  #{r.strip}" }
    f.puts '</HealthData>'
  end
end

xml_path    = ARGV[0] || abort('Usage: ruby scripts/gen_sample.rb <export.xml>')
output_path = 'data/sample.xml'

abort("File not found: #{xml_path}") unless File.exist?(xml_path)

$stderr.puts "Scanning #{xml_path}..."
records = collect_records(xml_path)
write_sample_xml(records, output_path)
$stderr.puts "Written #{records.size} records to #{output_path}"
```

- [ ] **Step 2: 実行して sample.xml を生成**

```bash
bundle exec ruby scripts/gen_sample.rb export.xml
```

Expected stderr:
```
Scanning export.xml...
Written 80 records to data/sample.xml
```
（VO2Max や BodyFatPercentage が少ない場合は WARN が出ることがある）

- [ ] **Step 3: 内容確認**

```bash
grep -c '<Record ' data/sample.xml
head -3 data/sample.xml
```

Expected: Record 行が最大80、XMLが正常構造（`<?xml ...` で始まる）

- [ ] **Step 4: commit**

```bash
git add scripts/gen_sample.rb data/sample.xml
git commit -m "feat: add gen_sample.rb to extract sample records from export.xml"
```

---

### Task 3: extract.rb — 定数・引数パース・CSV初期化の骨格

**Files:**
- Create: `scripts/extract.rb`

- [ ] **Step 1: extract.rb の骨格を作成**

```ruby
# frozen_string_literal: true
# Usage: bundle exec ruby scripts/extract.rb <xml> [from_yyyymmdd to_yyyymmdd [grain]]
# grain: full | daily | weekly | monthly  (default: full)

require 'ox'
require 'csv'
require 'date'
require 'time'
require 'fileutils'

TARGETS = {
  'HKQuantityTypeIdentifierStepCount'          => 'StepCount',
  'HKQuantityTypeIdentifierBodyMass'           => 'BodyMass',
  'HKQuantityTypeIdentifierHeartRate'          => 'HeartRate',
  'HKQuantityTypeIdentifierRestingHeartRate'   => 'RestingHeartRate',
  'HKQuantityTypeIdentifierActiveEnergyBurned' => 'ActiveEnergyBurned',
  'HKQuantityTypeIdentifierVO2Max'             => 'VO2Max',
  'HKQuantityTypeIdentifierBodyFatPercentage'  => 'BodyFatPercentage',
  'HKCategoryTypeIdentifierSleepAnalysis'      => 'SleepAnalysis',
}.freeze

AGGREGATION = {
  'StepCount'          => :sum,
  'BodyMass'           => :mean,
  'HeartRate'          => :mean,
  'RestingHeartRate'   => :mean,
  'ActiveEnergyBurned' => :sum,
  'VO2Max'             => :mean,
  'BodyFatPercentage'  => :mean,
  'SleepAnalysis'      => :sleep,
}.freeze

CSV_HEADERS = %w[creationDate startDate endDate value unit sourceName].freeze
OUTPUT_DIR  = 'output'.freeze
VALID_GRAINS = %w[full daily weekly monthly].freeze

def parse_args(argv)
  xml_path = argv[0] || abort('Usage: ruby scripts/extract.rb <xml> [from to [grain]]')
  abort("File not found: #{xml_path}") unless File.exist?(xml_path)

  from_date = argv[1] ? Date.strptime(argv[1], '%Y%m%d') : nil
  to_date   = argv[2] ? Date.strptime(argv[2], '%Y%m%d') : nil
  grain     = argv[3] || 'full'

  abort("grain must be: #{VALID_GRAINS.join('|')}") unless VALID_GRAINS.include?(grain)
  abort('Specify both from and to, or neither') if from_date.nil? != to_date.nil?

  [xml_path, from_date, to_date, grain]
end

def build_writers
  FileUtils.mkdir_p(OUTPUT_DIR)
  TARGETS.each_with_object({}) do |(_, metric), writers|
    path = File.join(OUTPUT_DIR, "#{metric}.csv")
    csv  = CSV.open(path, 'w', encoding: 'UTF-8')
    csv << CSV_HEADERS
    writers[metric] = csv
  end
end

def close_writers(writers)
  writers.each_value(&:close)
end

xml_path, from_date, to_date, grain = parse_args(ARGV)
writers = build_writers

$stderr.puts "Starting extraction: #{xml_path}"
$stderr.puts "Period: #{from_date || 'all'} - #{to_date || 'all'}, grain: #{grain}"

close_writers(writers)
$stderr.puts 'Done (SAX handler not yet implemented)'
```

- [ ] **Step 2: 引数なしでエラーを確認**

```bash
bundle exec ruby scripts/extract.rb
```

Expected: `Usage: ruby scripts/extract.rb <xml> [from to [grain]]`

- [ ] **Step 3: sample.xml で骨格が動くことを確認**

```bash
bundle exec ruby scripts/extract.rb data/sample.xml
wc -l output/*.csv
```

Expected: 全8CSVが生成され、各ファイルがヘッダ行のみ（`2 output/XXX.csv` ではなく `1 output/XXX.csv`）

- [ ] **Step 4: 不正 grain でエラーを確認**

```bash
bundle exec ruby scripts/extract.rb data/sample.xml 20240101 20241231 hourly
```

Expected: `grain must be: full|daily|weekly|monthly`

- [ ] **Step 5: commit**

```bash
git add scripts/extract.rb
git commit -m "feat: add extract.rb skeleton with arg parsing and CSV writer setup"
```

---

### Task 4: SaxHandler — SAX コールバック + full grain 出力

**Files:**
- Modify: `scripts/extract.rb`（`close_writers` の直後に SaxHandler クラスを挿入、main コードを更新）

- [ ] **Step 1: SaxHandler クラスを追加**

`close_writers` メソッドの定義の直後、main コードの前に挿入:

```ruby
class SaxHandler < Ox::Sax
  def initialize(writers, from_date, to_date, grain)
    @writers = writers
    @from    = from_date
    @to      = to_date
    @grain   = grain
    @attrs   = nil
    @count   = 0
    @buffers = {}
  end

  def start_element(name)
    @attrs = {} if name == :Record
  end

  def attr(name, value)
    @attrs[name] = value if @attrs
  end

  def end_element(name)
    return unless name == :Record && @attrs
    process_record(@attrs)
    @attrs = nil
  end

  def flush
    @buffers.each do |metric, keyed|
      keyed.each { |key, buf| write_aggregated(@writers[metric], key, metric, buf) }
    end
  end

  private

  def process_record(attrs)
    metric = TARGETS[attrs[:type]]
    return unless metric

    @count += 1
    $stderr.puts "Processed #{@count} records..." if (@count % 100_000).zero?

    return unless in_range?(attrs[:startDate])

    @grain == 'full' ? write_full(@writers[metric], attrs) : accumulate(metric, attrs)
  end

  def in_range?(start_date_str)
    return true if @from.nil?
    date = Date.parse(start_date_str)
    date >= @from && date <= @to
  end

  def write_full(csv, attrs)
    csv << [attrs[:creationDate], attrs[:startDate], attrs[:endDate],
            attrs[:value], attrs[:unit], attrs[:sourceName]]
  end

  def grain_key(start_date_str)
    date = Date.parse(start_date_str)
    case @grain
    when 'daily'   then date.strftime('%Y-%m-%d')
    when 'weekly'  then date.strftime('%Y-W%V')
    when 'monthly' then date.strftime('%Y-%m')
    end
  end

  def accumulate(metric, attrs)
    key = grain_key(attrs[:startDate])
    buf = (@buffers[metric] ||= {})[key] ||=
            { sum: 0.0, count: 0, last_creation: nil, last_end: nil, unit: nil }

    case AGGREGATION[metric]
    when :sum
      buf[:sum] += attrs[:value].to_f
    when :mean
      buf[:sum]   += attrs[:value].to_f
      buf[:count] += 1
    when :sleep
      start_t     = Time.parse(attrs[:startDate])
      end_t       = Time.parse(attrs[:endDate])
      buf[:sum]  += (end_t - start_t) / 60.0
    end

    buf[:last_creation] = attrs[:creationDate]
    buf[:last_end]      = attrs[:endDate]
    buf[:unit]          = attrs[:unit]
  end

  def write_aggregated(csv, key, metric, buf)
    value = case AGGREGATION[metric]
            when :sum   then buf[:sum].round(4)
            when :mean  then (buf[:sum] / buf[:count]).round(4)
            when :sleep then buf[:sum].round(2)
            end
    unit = AGGREGATION[metric] == :sleep ? 'min' : buf[:unit]
    csv << [buf[:last_creation], key, buf[:last_end], value, unit, 'aggregated']
  end
end
```

- [ ] **Step 2: main コードを更新（SaxHandler を使うよう変更）**

末尾の以下の行を:
```ruby
close_writers(writers)
$stderr.puts 'Done (SAX handler not yet implemented)'
```

以下に置き換え:
```ruby
handler = SaxHandler.new(writers, from_date, to_date, grain)

File.open(xml_path, 'rb') do |f|
  Ox.sax_parse(handler, f)
end

handler.flush unless grain == 'full'
close_writers(writers)
$stderr.puts 'Extraction complete.'
```

- [ ] **Step 3: full grain で sample.xml を実行**

```bash
bundle exec ruby scripts/extract.rb data/sample.xml
wc -l output/*.csv
```

Expected: ヘッダ行 + レコード行が存在すること（`1 output/XXX.csv` より大きい）

- [ ] **Step 4: 各CSVの先頭5行を確認**

```bash
head -5 output/StepCount.csv
head -5 output/SleepAnalysis.csv
head -5 output/BodyMass.csv
```

Expected:
- StepCount: `value` が数値文字列
- SleepAnalysis: `value` が `HKCategoryValueSleepAnalysis...` の文字列
- `sourceName` カラムにデバイス名が入っている

- [ ] **Step 5: 期間フィルタを確認**

まず全件のレコード数を確認:
```bash
wc -l output/StepCount.csv
```

次に sample.xml 内の実際の日付を確認してから期間を絞る:
```bash
head -3 output/StepCount.csv
```

確認した日付の一部だけをカバーする期間で再実行（例: 1年分）:
```bash
bundle exec ruby scripts/extract.rb data/sample.xml 20240101 20241231
wc -l output/StepCount.csv
```

Expected: 期間外レコードが除外され行数が減少している

- [ ] **Step 6: commit**

```bash
git add scripts/extract.rb
git commit -m "feat: add SaxHandler with full grain output and date range filtering"
```

---

### Task 5: 集約（daily / weekly / monthly）の確認

**Files:** `scripts/extract.rb`（実装は Task 4 で完了済み、動作確認のみ）

- [ ] **Step 1: daily 集約**

```bash
bundle exec ruby scripts/extract.rb data/sample.xml 20190101 20261231 daily
head -5 output/StepCount.csv
```

Expected:
- `startDate` カラムが `YYYY-MM-DD` 形式
- `sourceName` が `aggregated`
- `value` が数値（その日の歩数合計）

- [ ] **Step 2: monthly 集約**

```bash
bundle exec ruby scripts/extract.rb data/sample.xml 20190101 20261231 monthly
head -5 output/StepCount.csv
head -5 output/SleepAnalysis.csv
```

Expected:
- StepCount: `startDate` が `YYYY-MM` 形式
- SleepAnalysis: `value` が数値（合計分）、`unit` が `min`

- [ ] **Step 3: weekly 集約**

```bash
bundle exec ruby scripts/extract.rb data/sample.xml 20190101 20261231 weekly
head -5 output/HeartRate.csv
```

Expected: `startDate` が `YYYY-Www` 形式（例: `2024-W03`）、`value` が数値（平均）

- [ ] **Step 4: commit**

```bash
git add scripts/extract.rb
git commit -m "test: verify daily/weekly/monthly aggregation with sample.xml"
```

---

### Task 6: analyze.rb スタブ

**Files:**
- Create: `scripts/analyze.rb`

- [ ] **Step 1: analyze.rb 作成**

```ruby
# frozen_string_literal: true
# 分析スクリプト（未実装）
# Usage: bundle exec ruby scripts/analyze.rb

$stderr.puts 'analyze.rb: not yet implemented'
```

- [ ] **Step 2: 動作確認**

```bash
bundle exec ruby scripts/analyze.rb
```

Expected: `analyze.rb: not yet implemented`

- [ ] **Step 3: commit**

```bash
git add scripts/analyze.rb
git commit -m "chore: add analyze.rb stub"
```

---

### Task 7: フルデータ（export.xml）での最終検証

**Files:** なし（実行確認のみ）

- [ ] **Step 1: 全件・full grain で抽出**

```bash
time bundle exec ruby scripts/extract.rb export.xml 2>&1 | tail -10
```

Expected: `Extraction complete.` が出力される。進捗は10万件ごとに表示。

- [ ] **Step 2: 出力ファイルの規模確認**

```bash
wc -l output/*.csv
```

Expected: StepCount などは数万〜数十万行

- [ ] **Step 3: 各CSVの先頭を確認**

```bash
head -5 output/BodyMass.csv
head -5 output/RestingHeartRate.csv
head -5 output/VO2Max.csv
```

- [ ] **Step 4: 月次集約でフルデータを確認**

```bash
time bundle exec ruby scripts/extract.rb export.xml 20230101 20251231 monthly 2>&1 | tail -5
wc -l output/*.csv
head -5 output/StepCount.csv
```

Expected: 行数が大幅に減少、`startDate` が `YYYY-MM` 形式

- [ ] **Step 5: commit**

```bash
git add -A
git commit -m "chore: verified full data extraction and monthly aggregation"
```
