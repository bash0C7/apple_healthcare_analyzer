# frozen_string_literal: true
# MCP stdio サーバー — db/health.db へのアドホッククエリ用
# .claude/settings.json の mcpServers セクションで設定。
# 直接起動: bundle exec ruby scripts/mcp_server.rb

require 'json'
require 'sqlite3'
require 'mcp'

DB_PATH   = File.expand_path('../../db/health.db', __FILE__).freeze
SAFE_STMT = /\A\s*SELECT\s/i.freeze

def open_db
  return nil unless File.exist?(DB_PATH)
  db = SQLite3::Database.new(DB_PATH, readonly: true)
  db.results_as_hash = true
  db.busy_timeout = 5000
  db
end

DB = open_db

class QueryHealthTool < MCP::Tool
  description <<~DESC.strip
    db/health.db に対してSELECTクエリを実行。
    テーブル:
      records(date TEXT, metric TEXT, value REAL, unit TEXT) — 日次集計データ、UNIQUE(metric, date)
      daily_summary(date PK, step_count, active_energy, body_mass, body_fat, heart_rate, resting_hr, hrv, respiratory_rate, vo2max, sleep_hours, asleep_hours, body_battery INTEGER, updated_at)
      meta(key PK, value) — ベースライン・ロード日時など
  DESC

  input_schema(
    properties: { sql: { type: 'string', description: 'SQL SELECT文' } },
    required: ['sql']
  )

  class << self
    def call(sql:, server_context:)
      if DB.nil?
        return MCP::Tool::Response.new(
          [{ type: 'text', text: "DB が見つかりません: #{DB_PATH}。load_db.rb を実行してください。" }],
          is_error: true
        )
      end
      unless SAFE_STMT.match?(sql.to_s.strip)
        return MCP::Tool::Response.new(
          [{ type: 'text', text: 'SELECT文のみ実行できます' }],
          is_error: true
        )
      end
      rows = DB.execute(sql.to_s.strip).first(2000)
      MCP::Tool::Response.new([{ type: 'text', text: JSON.generate(rows) }])
    rescue SQLite3::Exception => e
      MCP::Tool::Response.new([{ type: 'text', text: "SQL エラー: #{e.message}" }], is_error: true)
    end
  end
end

class GetDbInfoTool < MCP::Tool
  description 'DBのメタ情報（ベースライン・最終ロード日時・レコード数）を返す'
  input_schema(properties: {})

  class << self
    def call(server_context:)
      if DB.nil?
        return MCP::Tool::Response.new(
          [{ type: 'text', text: "DB が見つかりません: #{DB_PATH}" }],
          is_error: true
        )
      end
      meta   = DB.execute('SELECT key, value FROM meta ORDER BY key')
                 .each_with_object({}) { |r, h| h[r['key']] = r['value'] }
      counts = DB.execute('SELECT count(*) AS n FROM records').first&.fetch('n', 0)
      meta['total_records'] = counts
      MCP::Tool::Response.new([{ type: 'text', text: JSON.generate(meta) }])
    rescue SQLite3::Exception => e
      MCP::Tool::Response.new([{ type: 'text', text: "SQL エラー: #{e.message}" }], is_error: true)
    end
  end
end

server    = MCP::Server.new(name: 'health-db', version: '1.0.0', tools: [QueryHealthTool, GetDbInfoTool])
transport = MCP::Server::Transports::StdioTransport.new(server)
transport.open
