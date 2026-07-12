package mailer

import (
	"context"
	"fmt"

	"github.com/resend/resend-go/v2"
)

// Resend sends through resend.com (3,000 emails/month free tier). Until a
// domain is DNS-verified, the sandbox sender only delivers to the account
// owner's address.
type Resend struct {
	client *resend.Client
	from   string
}

func NewResend(apiKey, from string) *Resend {
	return &Resend{client: resend.NewClient(apiKey), from: from}
}

func (r *Resend) SendLoginCode(ctx context.Context, to, code string) error {
	// The code leads the body: .oneTimeCode autofill only helps when mail
	// is read on the same device, so it must be trivially copyable too.
	_, err := r.client.Emails.SendWithContext(ctx, &resend.SendEmailRequest{
		From:    r.from,
		To:      []string{to},
		Subject: fmt.Sprintf("%s is your Squatter login code", code),
		Text: fmt.Sprintf(
			"Your Squatter login code: %s\n\nIt expires in 10 minutes. "+
				"If you didn't request it, ignore this email.", code),
	})
	return err
}
