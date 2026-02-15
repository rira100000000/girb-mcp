# frozen_string_literal: true

# シナリオ: 木構造の探索で特定ノードの状態を調査
# ブレークポイントを条件付きで設定して、特定の条件で止める

class TreeNode
  attr_accessor :value, :children, :metadata

  def initialize(value, metadata: {})
    @value = value
    @children = []
    @metadata = metadata
  end

  def add(*values)
    values.each do |v|
      child = TreeNode.new(v)
      @children << child
      yield child if block_given?
    end
    self
  end

  def find(target)
    return self if value == target

    children.each do |child|
      result = child.find(target)
      return result if result
    end

    nil
  end

  def depth_first(&block)
    block.call(self)
    children.each { |c| c.depth_first(&block) }
  end

  def total_nodes
    1 + children.sum(&:total_nodes)
  end

  def max_depth(current = 0)
    if children.empty?
      current
    else
      children.map { |c| c.max_depth(current + 1) }.max
    end
  end

  def to_s(indent = 0)
    result = "#{" " * indent}#{value}\n"
    children.each { |c| result += c.to_s(indent + 2) }
    result
  end
end

# 組織図を構築
company = TreeNode.new("CEO")

company.add("CTO") do |cto|
  cto.add("VP Engineering") do |vp|
    vp.add("Team Lead A") do |tl|
      tl.add("Engineer 1", "Engineer 2", "Engineer 3")
    end
    vp.add("Team Lead B") do |tl|
      tl.add("Engineer 4", "Engineer 5")
    end
  end
  cto.add("VP Product") do |vp|
    vp.add("PM 1", "PM 2")
  end
end

company.add("CFO") do |cfo|
  cfo.add("Controller") do |ctrl|
    ctrl.add("Accountant 1", "Accountant 2")
  end
end

company.add("COO") do |coo|
  coo.add("VP Operations") do |vp|
    vp.add("Manager 1", "Manager 2", "Manager 3")
  end
end

debugger

puts company.to_s
puts "Total nodes: #{company.total_nodes}"
puts "Max depth: #{company.max_depth}"

# 特定のノードを検索
target = company.find("Engineer 3")
puts "Found: #{target&.value || 'not found'}"
