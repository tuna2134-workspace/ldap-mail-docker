require ["fileinto", "mailbox"];

# Rspamd's milter_headers "spam-header" routine adds X-Spam-Flag: YES when the
# message's action is at least "add header".  Deliver those into Junk instead
# of INBOX.
if header :contains "X-Spam-Flag" "YES" {
    fileinto :create "Junk";
    stop;
}
