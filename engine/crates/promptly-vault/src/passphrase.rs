//! How easy a passphrase would be to guess.
//!
//! There are no rules about length or which characters to use. Instead the
//! estimate counts, roughly, how many guesses someone would need who knows
//! the usual tricks: the passwords people use most, repeated characters,
//! runs like `abc` or `1234`, and keyboard rows like `qwerty`. Only a
//! passphrase that would fall almost at once is refused; anything else is
//! shown on a meter with a word of advice, and the choice is the person's.

/// From "would be guessed almost at once" to "strong".
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Strength {
    /// Refused: it would be among the first things tried.
    TooWeak,
    Weak,
    Fair,
    Strong,
}

/// What the estimate found, and what to say about it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Assessment {
    pub strength: Strength,
    /// Roughly how many bits of guessing it would take.
    pub bits: u32,
    /// One or two plain sentences for the person choosing it.
    pub advice: &'static str,
}

impl Assessment {
    /// Whether it may lock a vault.
    pub fn allowed(&self) -> bool {
        self.strength > Strength::TooWeak
    }
}

/// Below this a passphrase is refused.
const TOO_WEAK_BELOW: f64 = 30.0;
const WEAK_BELOW: f64 = 50.0;
const FAIR_BELOW: f64 = 70.0;

/// The passwords people use most, lower-cased. A passphrase that is one of
/// these, give or take digits and punctuation at the end, is refused.
const COMMON: &[&str] = &[
    "password",
    "passw0rd",
    "p@ssword",
    "p@ssw0rd",
    "passphrase",
    "pass",
    "secret",
    "123456",
    "1234567",
    "12345678",
    "123456789",
    "1234567890",
    "0987654321",
    "987654321",
    "111111",
    "000000",
    "123123",
    "654321",
    "666666",
    "121212",
    "112233",
    "qwerty",
    "qwertyuiop",
    "qwerty123",
    "azerty",
    "asdfgh",
    "asdfghjkl",
    "zxcvbnm",
    "1q2w3e",
    "1q2w3e4r",
    "1qaz2wsx",
    "qazwsx",
    "abc",
    "abc123",
    "abcd1234",
    "abcdef",
    "iloveyou",
    "letmein",
    "welcome",
    "admin",
    "administrator",
    "root",
    "toor",
    "login",
    "changeme",
    "default",
    "guest",
    "master",
    "monkey",
    "dragon",
    "football",
    "baseball",
    "soccer",
    "hockey",
    "basketball",
    "princess",
    "sunshine",
    "shadow",
    "superman",
    "batman",
    "trustno1",
    "starwars",
    "whatever",
    "freedom",
    "hello",
    "hello123",
    "charlie",
    "michael",
    "jennifer",
    "jordan",
    "hunter",
    "hunter2",
    "ranger",
    "buster",
    "thomas",
    "tigger",
    "robert",
    "killer",
    "pepper",
    "ginger",
    "summer",
    "winter",
    "spring",
    "autumn",
    "flower",
    "cheese",
    "computer",
    "internet",
    "access",
    "mustang",
    "harley",
    "maggie",
    "love",
    "lovely",
    "loveme",
    "iloveu",
    "ashley",
    "bailey",
    "daniel",
    "andrew",
    "joshua",
    "matrix",
    "q1w2e3r4",
    "zaq12wsx",
    "1qazxsw2",
    "promptly",
    "vault",
    "myvault",
    "mypassword",
    "letmein1",
    "welcome1",
    "password1",
];

/// Rows of a keyboard, for runs like `qwerty` and `asdf`.
const ROWS: &[&str] = &[
    "1234567890",
    "qwertyuiop",
    "asdfghjkl",
    "zxcvbnm",
    "azertyuiop",
];

/// Estimate how easy `passphrase` would be to guess.
pub fn assess(passphrase: &str) -> Assessment {
    let chars: Vec<char> = passphrase.chars().collect();
    if chars.is_empty() {
        return Assessment {
            strength: Strength::TooWeak,
            bits: 0,
            advice: "Type a passphrase.",
        };
    }
    let lower: Vec<char> = passphrase.to_lowercase().chars().collect();
    let (bits, cheap, common) = score(&chars, &lower);

    let strength = if bits < TOO_WEAK_BELOW {
        Strength::TooWeak
    } else if bits < WEAK_BELOW {
        Strength::Weak
    } else if bits < FAIR_BELOW {
        Strength::Fair
    } else {
        Strength::Strong
    };
    let advice = match strength {
        Strength::TooWeak if common => {
            "This is one of the passwords people use most, so it would be among the first \
             guessed. Try a few words that don't belong together."
        }
        Strength::TooWeak if cheap * 2 >= chars.len() => {
            "Repeated letters and runs like abc, 1234 or qwerty are guessed quickly. Try a few \
             words that don't belong together."
        }
        Strength::TooWeak => {
            "This is short enough to be guessed quickly. Try a few words that don't belong \
             together, like a short phrase."
        }
        Strength::Weak => "Someone determined could guess this. Add another word or two.",
        Strength::Fair => "Good. One more word would make it strong.",
        Strength::Strong => "Strong. Make sure it is one you will remember.",
    };
    Assessment {
        strength,
        bits: bits.round() as u32,
        advice,
    }
}

/// Ok, or why the passphrase is refused.
pub fn check(passphrase: &str) -> Result<(), &'static str> {
    let a = assess(passphrase);
    if a.allowed() {
        Ok(())
    } else {
        Err(a.advice)
    }
}

/// Bits to guess `chars`, how many of them were predictable, and whether
/// it is built on a common password.
fn score(chars: &[char], lower: &[char]) -> (f64, usize, bool) {
    if lower.len() == chars.len() {
        if let Some(p) = whole_repeat(lower) {
            // Typing the same thing again costs only saying how many times.
            let (bits, _, common) = score(&chars[..p], &lower[..p]);
            let copies = lower.len() as f64 / p as f64;
            return (bits + 2.0 + copies.log2(), lower.len() - p, common);
        }
    }
    let common = is_common(lower);
    if common {
        // The base word is among the first tried; only what was added to
        // it counts.
        let base = common_base_len(lower);
        let (rest, cheap) = pattern_bits(&chars[base..], &lower[base..]);
        return (10.0 + rest, cheap + base, true);
    }
    let (bits, cheap) = pattern_bits(chars, lower);
    (bits, cheap, common)
}

/// The shortest chunk that `s` is made of, typed again and again (the last
/// copy may be cut short), when `s` is at least two copies of it.
fn whole_repeat(s: &[char]) -> Option<usize> {
    (1..=s.len() / 2).find(|&p| (p..s.len()).all(|i| s[i] == s[i - p]))
}

/// Bits to guess `chars`, and how many of them were predictable. A fresh
/// character costs its whole alphabet. A stretch of repeats, of a run or of
/// a repeated chunk costs only saying how long it goes on, so making one
/// longer hardly helps.
fn pattern_bits(chars: &[char], lower: &[char]) -> (f64, usize) {
    let mut bits = 0.0;
    let mut cheap = 0usize;
    let mut stretch = 0usize;
    let end_stretch = |stretch: &mut usize, bits: &mut f64| {
        if *stretch > 0 {
            *bits += 2.0 + (*stretch as f64).log2();
            *stretch = 0;
        }
    };
    for i in 0..chars.len() {
        let predictable = i > 0
            && (lower[i] == lower[i - 1]
                || in_run(lower[i - 1], lower[i])
                || repeats_chunk(lower, i));
        if predictable {
            cheap += 1;
            stretch += 1;
        } else {
            end_stretch(&mut stretch, &mut bits);
            bits += alphabet_bits(chars[i]);
        }
    }
    end_stretch(&mut stretch, &mut bits);
    (bits, cheap)
}

/// Bits to guess one character with nothing to go on but its kind.
fn alphabet_bits(c: char) -> f64 {
    let size: f64 = if c.is_ascii_lowercase() || c.is_ascii_uppercase() {
        26.0
    } else if c.is_ascii_digit() {
        10.0
    } else if c == ' ' {
        // Spaces between words are expected.
        2.0
    } else if c.is_ascii() {
        33.0
    } else {
        // Letters from other alphabets, accents, emoji.
        64.0
    };
    size.log2()
}

/// `b` follows `a` in the alphabet, in digits, or along a keyboard row,
/// either way round.
fn in_run(a: char, b: char) -> bool {
    let (x, y) = (a as u32, b as u32);
    let same_kind = (a.is_ascii_lowercase() && b.is_ascii_lowercase())
        || (a.is_ascii_digit() && b.is_ascii_digit());
    if same_kind && (x + 1 == y || y + 1 == x) {
        return true;
    }
    ROWS.iter().any(|row| {
        let row: Vec<char> = row.chars().collect();
        row.windows(2)
            .any(|w| (w[0] == a && w[1] == b) || (w[0] == b && w[1] == a))
    })
}

/// The character at `i` and the one before it repeat a short chunk just
/// before them, as in `abcabc` or `1212`.
fn repeats_chunk(s: &[char], i: usize) -> bool {
    (2..=4).any(|p| i > p && s[i] == s[i - p] && s[i - 1] == s[i - 1 - p])
}

/// Digits and punctuation at the end, which people add to meet rules.
fn trimmed(s: &[char]) -> &[char] {
    let mut end = s.len();
    while end > 0 && (s[end - 1].is_ascii_digit() || s[end - 1].is_ascii_punctuation()) {
        end -= 1;
    }
    &s[..end]
}

fn is_common(lower: &[char]) -> bool {
    let whole: String = lower.iter().collect();
    let base: String = trimmed(lower).iter().collect();
    COMMON.contains(&whole.trim()) || (!base.is_empty() && COMMON.contains(&base.trim()))
}

/// How much of `lower` is the common word, without what was added after.
fn common_base_len(lower: &[char]) -> usize {
    let whole: String = lower.iter().collect();
    if COMMON.contains(&whole.trim()) {
        return lower.len();
    }
    trimmed(lower).len()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strength(p: &str) -> Strength {
        assess(p).strength
    }

    #[test]
    fn common_passwords_are_refused_with_or_without_a_suffix() {
        for p in [
            "password",
            "Password1!",
            "qwerty123",
            "letmein",
            "12345678",
            "iloveyou2024",
        ] {
            assert_eq!(strength(p), Strength::TooWeak, "{p}");
            assert!(assess(p).advice.contains("use most"), "{p}");
        }
    }

    #[test]
    fn repeats_and_runs_are_refused() {
        for p in [
            "aaaaaaaaaaaa",
            "abcdefghij",
            "qwertyuiopas",
            "abcabcabcabc",
            "98765432",
        ] {
            assert_eq!(strength(p), Strength::TooWeak, "{p}");
        }
        assert!(assess("aaaaaaaaaaaa").advice.contains("runs like abc"));
    }

    #[test]
    fn making_a_pattern_longer_does_not_make_it_strong() {
        let long_digits = format!("password{}", "0".repeat(30));
        for p in [
            "a".repeat(48),
            "a".repeat(18),
            "ab".repeat(30),
            "abc1".repeat(20),
            "1234567890".repeat(5),
            long_digits,
            "password".repeat(3),
            "Password1!".repeat(4),
            "hello".repeat(6),
        ] {
            assert_eq!(strength(&p), Strength::TooWeak, "{p}");
        }
        // A word typed four times is no stronger than typed once.
        assert_eq!(strength(&"sunflower".repeat(4)), strength("sunflower"));
    }

    #[test]
    fn short_ones_are_refused_and_say_why() {
        let a = assess("mydog");
        assert_eq!(a.strength, Strength::TooWeak);
        assert!(a.advice.contains("short"));
        assert!(check("mydog").is_err());
        assert_eq!(assess("").advice, "Type a passphrase.");
    }

    #[test]
    fn no_rules_about_kinds_of_character() {
        // All lower case, no digits, no symbols: still strong when long.
        assert_eq!(strength("correct horse battery staple"), Strength::Strong);
        assert!(check("correct horse battery staple").is_ok());
        // Mixed characters do not make a short one strong.
        assert!(strength("Tr0ub4dor&3") < Strength::Strong);
    }

    #[test]
    fn the_meter_climbs_with_length() {
        let steps = [
            "kitten",
            "purple kitten",
            "purple kitten lamp",
            "purple kitten lamp oyster",
        ];
        let levels: Vec<Strength> = steps.iter().map(|p| strength(p)).collect();
        assert!(levels.windows(2).all(|w| w[0] <= w[1]), "{levels:?}");
        assert_eq!(levels[0], Strength::TooWeak);
        assert!(levels[1] > Strength::Weak);
        assert_eq!(levels[3], Strength::Strong);
    }

    #[test]
    fn other_alphabets_count() {
        assert!(check("сложный пароль").is_ok());
    }
}
