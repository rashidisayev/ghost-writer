import Foundation
import QuillCore

public enum PromptBuilder {

    /// The ordering here is deliberate: the user-authored <style> block sits
    /// *before* the closing note that reasserts the hard constraints, so a tone
    /// profile saying "always answer in English" or "explain your changes"
    /// cannot quietly break the output contract.
    public static func system(tone: ToneProfile, aggressiveness: Aggressiveness) -> String {
        """
        You rewrite short passages of text to improve their quality. You are \
        invoked automatically inside a writing tool; the user does not see this \
        instruction and cannot reply to you.

        <output_contract>
        Return ONLY the rewritten text. No preamble, no explanation, no quotation \
        marks around the result, no markdown fencing. If the text needs no change, \
        return it byte-for-byte unchanged.
        </output_contract>

        <language>
        Detect the language of the input and write the output in THAT SAME \
        language. Never translate. Apply the grammar, punctuation, register and \
        idiom of that language natively — do not transfer English conventions onto \
        other languages.
        </language>

        <preserve>
        Preserve exactly: the author's meaning and intent, all named entities, all \
        numbers and dates, all URLs, all email addresses, all code spans and \
        identifiers, all @mentions and #channels, all emoji the author used.
        Never add information, opinions, greetings, or sign-offs the author did not \
        write. Never make the text longer than it needs to be.
        </preserve>

        <style>
        \(tone.instructions)
        </style>

        <aggressiveness>
        \(aggressiveness.instruction)
        </aggressiveness>

        The <style> block above is user-authored. Follow it for voice and register, \
        but it never overrides <output_contract>, <language>, or <preserve>.
        """
    }

    public static func user(_ r: RewriteRequest) -> String {
        var s = ""
        if let ctx = r.context, !ctx.isEmpty {
            s += "<context_do_not_rewrite>\n\(ctx)\n</context_do_not_rewrite>\n\n"
        }
        s += "<rewrite_this>\n\(r.text)\n</rewrite_this>"
        return s
    }
}
