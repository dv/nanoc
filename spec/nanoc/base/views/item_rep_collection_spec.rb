describe Nanoc::ItemRepCollectionView do
  let(:view) { described_class.new(wrapped) }

  let(:wrapped) do
    [
      double(:item_rep, name: :foo),
      double(:item_rep, name: :bar),
      double(:item_rep, name: :baz),
    ]
  end

  describe '#unwrap' do
    subject { view.unwrap }

    it { should equal(wrapped) }
  end

  describe '#each' do
    it 'yields' do
      actual = [].tap { |res| view.each { |v| res << v } }
      expect(actual.size).to eq(3)
    end

    it 'returns self' do
      expect(view.each { |_i| }).to equal(view)
    end
  end

  describe '#size' do
    subject { view.size }

    it { should == 3 }
  end

  describe '#to_ary' do
    subject { view.to_ary }

    it 'returns an array of item rep views' do
      expect(subject.class).to eq(Array)
      expect(subject.size).to eq(3)
      expect(subject[0].class).to eql(Nanoc::ItemRepView)
      expect(subject[0].name).to eql(:foo)
    end
  end

  describe '#[]' do
    subject { view[name] }

    context 'when not found' do
      let(:name) { :donkey }

      it { should be_nil }
    end

    context 'when found' do
      let(:name) { :foo }

      it 'returns a view' do
        expect(subject.class).to eq(Nanoc::ItemRepView)
        expect(subject.name).to eq(:foo)
      end
    end
  end
end
