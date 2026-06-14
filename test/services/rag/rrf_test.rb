require "test_helper"

class Rag::RrfTest < ActiveSupport::TestCase
  Doc = Struct.new(:id, :src)

  # Plain integers fuse by identity (id: :itself default).
  test "an item ranked high in both lists wins" do
    vector = [ 1, 2, 3 ]
    text   = [ 3, 4, 1 ]
    # 1: 1/61 + 1/63, 3: 1/63 + 1/61 -> tie; 1 before 3 by first-seen order.
    assert_equal [ 1, 3, 2, 4 ], Rag::Rrf.fuse(vector, text)
  end

  test "consensus beats a single first place" do
    # 2 is rank-1 in one list only; 1 is rank-2 in both -> 1 should win.
    fused = Rag::Rrf.fuse([ 2, 1 ], [ 3, 1 ])
    assert_equal 1, fused.first
  end

  test "deduplicates while keeping the first object seen" do
    a = +"x"
    b = +"x"
    fused = Rag::Rrf.fuse([ a ], [ b ], id: :itself)
    assert_equal 1, fused.size
    assert_same a, fused.first
  end

  test "fuses by an id selector and keeps the object" do
    v = [ Doc.new(1, :vec), Doc.new(2, :vec) ]
    t = [ Doc.new(2, :txt), Doc.new(3, :txt) ]
    fused = Rag::Rrf.fuse(v, t, id: :id)

    assert_equal [ 2, 1, 3 ], fused.map(&:id)
    assert_equal :vec, fused.find { |d| d.id == 2 }.src, "keeps the first object seen for an id"
  end

  test "smaller k sharpens the advantage of top ranks" do
    # With small k, rank-1 dominates; the item that is rank-1 in one list and
    # absent in the other should lead.
    fused = Rag::Rrf.fuse([ 9, 8, 7 ], [ 1, 2, 3 ], k: 1)
    assert_includes [ 9, 1 ], fused.first
  end
end
