import UIKit

/// Browses the active Rime segment without changing the four candidates in the toolbar.
final class CandidatePanel: UIStackView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private let lengths = UISegmentedControl(items: ["全部", "1 字", "2 字", "3 字", "4 字以上"])
    private let words: UICollectionView
    private let empty = UILabel()
    private let fetch: (Int, Int) -> [String]
    private let pick: (Int) -> Void
    private var matches: [(index: Int, text: String)] = []
    var wordFont = UIFont.systemFont(ofSize: 18) {
        didSet {
            guard wordFont != oldValue else { return }
            words.collectionViewLayout.invalidateLayout()
            words.reloadData()
        }
    }
    private var nextIndex = 0
    private var hasMore = false
    private var loading: Task<Void, Never>?

    init(fetch: @escaping (Int, Int) -> [String], pick: @escaping (Int) -> Void) {
        self.fetch = fetch
        self.pick = pick
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        layout.sectionInset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        words = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)
        axis = .vertical
        spacing = 2
        lengths.selectedSegmentIndex = 0
        lengths.accessibilityLabel = "按候选字数筛选"
        lengths.addAction(UIAction { [weak self] _ in self?.reload() }, for: .valueChanged)
        addArrangedSubview(lengths)
        words.backgroundColor = .systemGray5
        words.contentInsetAdjustmentBehavior = .never
        if #available(iOS 26.0, *) {
            words.topEdgeEffect.isHidden = true
            words.bottomEdgeEffect.isHidden = true
        }
        words.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "word")
        words.dataSource = self
        words.delegate = self
        empty.text = "没有符合字数的候选"
        empty.textAlignment = .center
        empty.textColor = .secondaryLabel
        words.backgroundView = empty
        addArrangedSubview(words)
        isHidden = true
    }

    required init(coder: NSCoder) { fatalError("Use init(fetch:pick:)") }

    func show() {
        isHidden = false
        lengths.selectedSegmentIndex = 0
        reload()
    }

    func dismiss() {
        isHidden = true
        loading?.cancel()
        loading = nil
        matches.removeAll()
    }

    private func reload() {
        loading?.cancel()
        loading = nil
        matches.removeAll(keepingCapacity: true)
        nextIndex = 0
        hasMore = true
        words.setContentOffset(.zero, animated: false)
        loadMore()
    }

    private func loadMore() {
        guard hasMore, loading == nil else { return }
        let length = lengths.selectedSegmentIndex
        let minimumNewMatches = 40
        empty.isHidden = true
        loading = Task { @MainActor [weak self] in
            guard let self else { return }
            var newMatches: [(index: Int, text: String)] = []
            while !Task.isCancelled && hasMore && newMatches.count < minimumNewMatches {
                let batch = fetch(nextIndex, 32)
                for (offset, text) in batch.enumerated() where length == 0 || min(text.count, 4) == length {
                    newMatches.append((nextIndex + offset, text))
                }
                nextIndex += batch.count
                hasMore = batch.count == 32
                // Some syllables have hundreds of entries. Keep scrolling and closing responsive.
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
            matches.append(contentsOf: newMatches)
            loading = nil
            words.reloadData()
            empty.isHidden = !matches.isEmpty || hasMore
        }
        words.reloadData()
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        matches.count + (hasMore && loading == nil ? 1 : 0)
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = words.dequeueReusableCell(withReuseIdentifier: "word", for: indexPath)
        let isWord = matches.indices.contains(indexPath.item)
        let title = isWord ? matches[indexPath.item].text : "更多候选"
        var content = UIListContentConfiguration.cell()
        content.text = title
        content.textProperties.font = wordFont
        content.textProperties.adjustsFontForContentSizeCategory = false
        content.textProperties.alignment = .center
        content.textProperties.numberOfLines = 1
        content.directionalLayoutMargins = .zero
        cell.contentConfiguration = content
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = .secondarySystemBackground
        background.cornerRadius = 6
        cell.backgroundConfiguration = background
        cell.isAccessibilityElement = true
        cell.accessibilityTraits = .button
        cell.accessibilityLabel = title
        cell.accessibilityIdentifier = isWord ? "candidate-grid-word" : "candidate-grid-more"
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let text = matches.indices.contains(indexPath.item) ? matches[indexPath.item].text : "更多候选"
        let width = (text as NSString).size(withAttributes: [.font: wordFont]).width
        return CGSize(width: min(max(52, ceil(width) + 24), max(52, collectionView.bounds.width - 8)),
                      height: max(42, ceil(wordFont.lineHeight) + 10))
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if matches.indices.contains(indexPath.item) { pick(matches[indexPath.item].index) }
        else { loadMore() }
    }
}
