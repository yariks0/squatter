import SwiftUI

/// The launch gate: passwordless sign-in with an emailed 6-digit code,
/// dressed in the Kodo visual language so it reads as the same product.
struct LoginView: View {
    let auth: AuthSession
    @State private var model: LoginModel
    @FocusState private var focus: Field?

    private enum Field { case email, code }

    init(auth: AuthSession) {
        self.auth = auth
        _model = State(initialValue: LoginModel(
            requestCode: { try await auth.requestCode(email: $0) },
            verify: { try await auth.verify(email: $0, code: $1) }
        ))
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Kodo.cardTop, Kodo.cardBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()
                KodoEmblem(size: 76)
                VStack(spacing: 6) {
                    Text("SQUATTER")
                        .font(.title2.weight(.bold))
                        .tracking(3)
                        .foregroundStyle(Kodo.inkPrimary)
                    Text("Sign in to sync your training")
                        .font(.subheadline)
                        .foregroundStyle(Kodo.inkSecondary)
                }

                card
                Spacer()
                Spacer()
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 460)
        }
    }

    @ViewBuilder private var card: some View {
        VStack(spacing: 16) {
            switch model.step {
            case .enterEmail: emailStep
            case let .enterCode(email): codeStep(email: email)
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Kodo.soulRedBright)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.step)
        .animation(.easeOut(duration: 0.2), value: model.errorMessage)
    }

    private var emailStep: some View {
        VStack(spacing: 16) {
            TextField("you@example.com", text: $model.email)
                .textFieldStyle(.plain)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .email)
                .submitLabel(.go)
                .onSubmit { Task { await model.sendCode() } }
                .padding(14)
                .background(fieldBackground)

            Button {
                Task { await model.sendCode() }
            } label: {
                Text(model.isBusy ? "Sending…" : "Send code")
            }
            .buttonStyle(KodoProminentButtonStyle(fullWidth: true))
            .disabled(!model.canSendCode)
            .opacity(model.canSendCode ? 1 : 0.5)
        }
        .onAppear { focus = .email }
    }

    private func codeStep(email: String) -> some View {
        VStack(spacing: 16) {
            Text("Enter the 6-digit code sent to \(email)")
                .font(.footnote)
                .foregroundStyle(Kodo.inkSecondary)
                .multilineTextAlignment(.center)

            TextField("000000", text: $model.code)
                .textFieldStyle(.plain)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(.system(.title, design: .rounded).weight(.semibold))
                .tracking(8)
                .focused($focus, equals: .code)
                .onChange(of: model.code) { _, newValue in
                    // Keep it to six digits; auto-submit when full.
                    let digits = String(newValue.filter(\.isNumber).prefix(6))
                    if digits != newValue { model.code = digits }
                    if digits.count == 6 { Task { await model.submitCode() } }
                }
                .padding(14)
                .background(fieldBackground)

            Button {
                Task { await model.submitCode() }
            } label: {
                Text(model.isBusy ? "Verifying…" : "Verify")
            }
            .buttonStyle(KodoProminentButtonStyle(fullWidth: true))
            .disabled(!model.canVerify)
            .opacity(model.canVerify ? 1 : 0.5)

            HStack {
                Button(resendLabel) { Task { await model.resendCode() } }
                    .disabled(!model.canResend)
                Spacer()
                Button("Use a different email") { model.changeEmail() }
            }
            .font(.footnote)
            .foregroundStyle(Kodo.inkSecondary)
        }
        .onAppear { focus = .code }
    }

    private var resendLabel: String {
        model.resendCountdown > 0 ? "Resend in \(model.resendCountdown)s" : "Resend code"
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Kodo.cardTop)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Kodo.hairline, lineWidth: 1)
            )
    }
}
