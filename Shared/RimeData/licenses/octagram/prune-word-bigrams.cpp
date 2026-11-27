// SPDX-License-Identifier: LGPL-3.0-only
#include "darts.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

namespace {
using Unit = Darts::Details::DoubleArrayUnit;
using Entry = std::pair<std::string, int>;

// librime-octagram's metadata precedes the double-array image. The rebuild
// script checks the upstream file digest before invoking this tool.
struct Metadata {
    std::array<char, 32> format;
    std::uint32_t checksum;
    std::uint32_t units;
    std::int32_t arrayOffset;
};
static_assert(sizeof(Metadata) == 44);
static_assert(sizeof(Unit) == 4 && std::is_trivially_copyable<Unit>::value);
constexpr int minimumScore = 110000;  // Upstream encodes ln(frequency) * 10,000.
constexpr std::uint32_t noChild = UINT32_MAX;

class WordBigrams {
public:
    explicit WordBigrams(std::istream& input) {
        input.read(reinterpret_cast<char*>(&metadata), sizeof(metadata));
        if (std::string(metadata.format.data(), 17) != "Rime::Grammar/1.0" ||
            metadata.arrayOffset != 4 || metadata.units != 10231296) {
            throw std::runtime_error("Expected the pinned upstream word-bigram model");
        }
        units.resize(metadata.units);
        input.read(reinterpret_cast<char*>(units.data()), units.size() * sizeof(Unit));
        // Transition L from a node's base is stored at (base XOR L). Build
        // a reverse index so enumeration visits only populated transitions.
        firstChild.assign(units.size(), noChild);
        nextSibling.assign(units.size(), noChild);
        for (std::uint32_t position = 0; position < units.size(); ++position) {
            const auto label = units[position].label();
            if (label == 0 || label > 255) continue;
            const auto base = position ^ label;
            nextSibling[position] = firstChild.at(base);
            firstChild[base] = position;
        }
    }

    void write(std::ostream& output) {
        std::string prefix;
        collect(0, prefix);
        std::sort(entries.begin(), entries.end());
        std::vector<const char*> keys;
        std::vector<int> scores;
        for (const auto& [key, score] : entries) {
            keys.push_back(key.c_str());
            scores.push_back(score);
        }
        Darts::DoubleArray compact;
        if (compact.build(keys.size(), keys.data(), nullptr, scores.data()) != 0) {
            throw std::runtime_error("Could not build compact trie");
        }
        metadata.units = static_cast<std::uint32_t>(compact.size());
        output.write(reinterpret_cast<const char*>(&metadata), sizeof(metadata));
        output.write(static_cast<const char*>(compact.array()), compact.total_size());
        std::cout << entries.size() << " word bigrams, "
                  << sizeof(metadata) + compact.total_size() << " bytes\n";
    }

private:
    void collect(std::uint32_t position, std::string& prefix) {
        const auto& node = units.at(position);
        const auto base = position ^ node.offset();
        if (node.has_leaf()) {
            const auto score = units.at(base).value();
            if (score >= minimumScore) entries.emplace_back(prefix, score);
        }
        for (auto child = firstChild.at(base); child != noChild; child = nextSibling[child]) {
            prefix.push_back(static_cast<char>(units[child].label()));
            collect(child, prefix);
            prefix.pop_back();
        }
    }
    Metadata metadata{};
    std::vector<Unit> units;
    std::vector<std::uint32_t> firstChild;
    std::vector<std::uint32_t> nextSibling;
    std::vector<Entry> entries;
};
}  // namespace

int main(int argc, char** argv) {
    if (argc != 3) {
        std::cerr << "Usage: prune-word-bigrams SOURCE.gram OUTPUT.gram\n";
        return 1;
    }
    try {
        std::ifstream source(argv[1], std::ios::binary);
        source.exceptions(std::ios::failbit | std::ios::badbit);
        WordBigrams model(source);
        std::ofstream output(argv[2], std::ios::binary);
        output.exceptions(std::ios::failbit | std::ios::badbit);
        model.write(output);
        output.close();
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
