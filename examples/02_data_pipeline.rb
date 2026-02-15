# frozen_string_literal: true

# シナリオ: CSVデータ変換パイプラインで一部のレコードが消える
# ステップ実行で各段階のデータを追跡する

require "csv"
require "stringio"

csv_data = <<~CSV
  id,name,age,score
  1,田中太郎,28,85
  2,鈴木花子,,92
  3,佐藤次郎,35,
  4,山田三郎,42,78
  5,高橋四郎,-3,95
CSV

class DataPipeline
  def initialize(csv_string)
    @raw = CSV.parse(csv_string, headers: true)
    @records = []
    @errors = []
  end

  def run
    parse
    validate
    transform
    { records: @records, errors: @errors, stats: stats }
  end

  private

  def parse
    @records = @raw.map do |row|
      {
        id: row["id"]&.to_i,
        name: row["name"],
        age: row["age"]&.to_i,     # nil.to_i => 0
        score: row["score"]&.to_i,  # nil.to_i => 0
      }
    end
  end

  def validate
    @records.reject! do |r|
      if r[:age] <= 0
        @errors << { id: r[:id], reason: "invalid age: #{r[:age]}" }
        true
      elsif r[:score] <= 0
        @errors << { id: r[:id], reason: "invalid score: #{r[:score]}" }
        true
      else
        false
      end
    end
  end

  def transform
    avg = @records.sum { |r| r[:score] } / @records.size.to_f
    @records.each do |r|
      r[:grade] = case r[:score]
                  when 90.. then "A"
                  when 80.. then "B"
                  when 70.. then "C"
                  else "D"
                  end
      r[:above_average] = r[:score] > avg
    end
  end

  def stats
    {
      total_input: @raw.size,
      valid_records: @records.size,
      error_count: @errors.size,
      average_score: @records.sum { |r| r[:score] } / @records.size.to_f,
    }
  end
end

pipeline = DataPipeline.new(csv_data)

debugger

result = pipeline.run

puts "=== 結果 ==="
puts "有効レコード: #{result[:records].size}"
result[:records].each { |r| puts "  #{r}" }
puts "エラー: #{result[:errors].size}"
result[:errors].each { |e| puts "  #{e}" }
puts "統計: #{result[:stats]}"
