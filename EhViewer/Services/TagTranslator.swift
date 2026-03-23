import Foundation

/// 日本語→E-Hentaiタグのローカル辞書翻訳
enum TagTranslator {

    /// 設定でON/OFF
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "tagTranslation")
    }

    /// 日本語入力をE-Hentaiタグに変換。マッチしないワードはそのまま返す。
    static func translate(_ query: String) -> String {
        guard isEnabled else { return query }

        let words = query.components(separatedBy: CharacterSet.whitespaces).filter { !$0.isEmpty }
        let translated = words.map { word -> String in
            // 完全一致
            if let tag = dictionary[word] { return tag }
            // 前方一致（複合語対応）
            for (key, value) in dictionary where word.hasPrefix(key) {
                return value
            }
            return word
        }
        let result = translated.joined(separator: " ")
        if result != query {
            LogManager.shared.log("TagTranslate", "input=\"\(query)\" output=\"\(result)\"")
        }
        return result
    }

    // MARK: - 辞書（日本語 → E-Hentai検索形式）

    static let dictionary: [String: String] = [
        // 身体特徴
        "巨乳": "female:\"big breasts$\"",
        "貧乳": "female:\"small breasts$\"",
        "爆乳": "female:\"huge breasts$\"",
        "金髪": "female:\"blonde hair$\"",
        "黒髪": "female:\"black hair$\"",
        "茶髪": "female:\"brown hair$\"",
        "赤髪": "female:\"red hair$\"",
        "銀髪": "female:\"silver hair$\"",
        "白髪": "female:\"white hair$\"",
        "ピンク髪": "female:\"pink hair$\"",
        "青髪": "female:\"blue hair$\"",
        "緑髪": "female:\"green hair$\"",
        "ツインテール": "female:twintails$",
        "ポニーテール": "female:ponytail$",
        "ショートヘア": "female:\"short hair$\"",
        "ロングヘア": "female:\"long hair$\"",
        "ロリ": "female:lolicon$",
        "熟女": "female:milf$",
        "人妻": "female:milf$",
        "筋肉": "female:muscle$",
        "褐色": "female:\"dark skin$\"",
        "黒人": "male:\"dark-skinned male$\"",
        "エルフ": "female:elf$",
        "獣耳": "female:\"animal ears$\"",
        "猫耳": "female:\"cat ears$\"",
        "狐耳": "female:\"fox ears$\"",
        "角": "female:horns$",
        "尻尾": "female:tail$",
        "眼鏡": "female:glasses$",
        "メガネ": "female:glasses$",
        "そばかす": "female:freckles$",
        "妊婦": "female:pregnant$",
        "妊娠": "female:pregnant$",
        "ふたなり": "female:futanari$",

        // 服装
        "メイド": "female:maid$",
        "ナース": "female:nurse$",
        "学生服": "female:\"school uniform$\"",
        "制服": "female:\"school uniform$\"",
        "セーラー服": "female:\"sailor uniform$\"",
        "ブレザー": "female:blazer$",
        "体操着": "female:\"gym uniform$\"",
        "ブルマ": "female:bloomers$",
        "スク水": "female:\"school swimsuit$\"",
        "水着": "female:swimsuit$",
        "水泳服": "female:swimsuit$",
        "ビキニ": "female:bikini$",
        "レオタード": "female:leotard$",
        "チャイナドレス": "female:\"china dress$\"",
        "着物": "female:kimono$",
        "浴衣": "female:yukata$",
        "バニーガール": "female:\"bunny girl$\"",
        "コスプレ": "female:cosplaying$",
        "ストッキング": "female:stockings$",
        "ニーソ": "female:\"thigh high boots$\"",
        "パンスト": "female:pantyhose$",
        "エプロン": "female:apron$",

        // 行為
        "中出し": "female:nakadashi$",
        "パイズリ": "female:paizuri$",
        "フェラ": "female:blowjob$",
        "アナル": "female:anal$",
        "オナニー": "female:masturbation$",
        "手コキ": "female:handjob$",
        "足コキ": "female:footjob$",
        "顔射": "female:\"facial cumshot$\"",
        "口内射精": "female:\"cum in mouth$\"",
        "飲精": "female:\"cum swallow$\"",
        "母乳": "female:lactation$",
        "潮吹き": "female:squirting$",
        "触手": "female:tentacles$",
        "拘束": "female:bondage$",
        "調教": "female:\"slave training$\"",
        "輪姦": "female:\"group sex$\"",
        "乱交": "female:\"group sex$\"",
        "逆レイプ": "female:\"reverse rape$\"",
        "和姦": "female:vanilla$",
        "レイプ": "female:rape$",
        "催眠": "female:hypnosis$",
        "薬": "female:drugs$",
        "寝取り": "female:netorare$",
        "寝取られ": "female:netorare$",
        "NTR": "female:netorare$",
        "百合": "female:yuri$",
        "ヤンデレ": "female:yandere$",
        "痴漢": "female:chikan$",

        // ジャンル・シチュエーション
        "女性優位": "female:femdom$",
        "女性上位": "female:femdom$",
        "男の娘": "male:\"males only$\"",
        "ショタ": "male:shotacon$",
        "おねショタ": "female:\"age progression$\"",
        "ハーレム": "female:harem$",
        "姉妹": "female:sisters$",
        "母娘": "female:\"mother daughter$\"",
        "近親": "female:incest$",
        "異世界": "parody:\"original work$\"",
        "ファンタジー": "female:elf$",
        "学園": "female:\"school uniform$\"",
        "教師": "female:teacher$",
        "先生": "female:teacher$",
        "幼馴染": "female:childhood$",
        "お姫様": "female:princess$",
        "魔法少女": "female:\"magical girl$\"",
        "吸血鬼": "female:vampire$",
        "サキュバス": "female:succubus$",
        "天使": "female:angel$",
        "悪魔": "female:demon$",
        "ロボット": "female:robot$",
        "アイドル": "female:idol$",

        // 属性
        "フルカラー": "misc:\"full color$\"",
        "モノクロ": "misc:\"monochrome$\"",
        "無修正": "misc:uncensored$",
        "日本語": "language:japanese$",
        "英語": "language:english$",
        "中国語": "language:chinese$",
        "韓国語": "language:korean$",
        "翻訳": "language:translated$",

        // パロディ
        "東方": "parody:\"touhou project$\"",
        "艦これ": "parody:\"kantai collection$\"",
        "Fate": "parody:\"fate grand order$\"",
        "フェイト": "parody:\"fate grand order$\"",
        "アイマス": "parody:\"the idolmaster$\"",
        "ラブライブ": "parody:\"love live$\"",
        "プリコネ": "parody:\"princess connect$\"",
        "ブルアカ": "parody:\"blue archive$\"",
        "原神": "parody:\"genshin impact$\"",
        "ウマ娘": "parody:\"umamusume$\"",
        "ワンピース": "parody:\"one piece$\"",
        "ドラゴンボール": "parody:\"dragon ball$\"",
        "ドラゴン": "parody:\"dragon ball$\"",
        "エヴァ": "parody:\"neon genesis evangelion$\"",
        "進撃の巨人": "parody:\"attack on titan$\"",
        "鬼滅": "parody:\"kimetsu no yaiba$\"",
        "呪術廻戦": "parody:\"jujutsu kaisen$\"",
        "チェンソーマン": "parody:\"chainsaw man$\"",
        "スパイファミリー": "parody:\"spy x family$\"",
        "リゼロ": "parody:\"re zero$\"",
        "このすば": "parody:konosuba$",
        "転スラ": "parody:\"tensei shitara slime$\"",
        "SAO": "parody:\"sword art online$\"",
        "ホロライブ": "parody:hololive$",
        "にじさんじ": "parody:nijisanji$",

        // 断面図
        "断面図": "misc:\"x-ray$\"",
    ]
}
