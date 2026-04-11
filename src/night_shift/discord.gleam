import gleam/json

@external(erlang, "night_shift_discord", "post_webhook")
fn post_webhook(url: String, payload: String, log_path: String) -> Result(String, String)

pub fn post_message(
  webhook_url: String,
  content: String,
  log_path: String,
) -> Result(String, String) {
  json.object([#("content", json.string(content))])
  |> json.to_string
  |> post_webhook(webhook_url, _, log_path)
}
