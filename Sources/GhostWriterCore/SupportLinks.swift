import Foundation

/// Outbound links the UI offers. Centralised so the donation address exists in
/// exactly one place — it is the kind of string that otherwise ends up
/// copy-pasted into three views and updated in one.
public enum SupportLinks {

    /// PayPal donation. The `business` parameter is the recipient's PayPal
    /// account address; PayPal resolves it server-side, so nothing is charged
    /// or collected by the app itself.
    public static let buyMeACoffee = URL(string:
        "https://www.paypal.com/donate/"
        + "?business=rashidisayev%40gmail.com"
        + "&item_name=Support%20Ghost%20Writer%20development"
        + "&currency_code=EUR"
        + "&no_recurring=0"
    )!

    public static let repository = URL(string:
        "https://github.com/rashidisayev/ghost-writer")!
}
