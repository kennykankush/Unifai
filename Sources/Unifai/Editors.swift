import SwiftUI
import UnifaiCore

struct EditorFrame<Fields: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let saveLabel: String
    let error: String?
    let save: () -> Void
    @ViewBuilder let fields: () -> Fields
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 22, weight: .bold)).padding(.horizontal, 24).padding(.top, 24)
            Form { fields() }.formStyle(.grouped)
            if let error { InlineNotice(text: error).padding(.horizontal, 24).accessibilityElement(children: .ignore).accessibilityLabel("Validation error: \(error)") }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button(saveLabel, action: save).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }
                .padding(.horizontal, 24).padding(.bottom, 24)
        }.frame(width: 540).frame(minHeight: 440, maxHeight: 650)
    }
}

struct AccountEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let integration: Integration
    let account: ConnectedAccount?
    @State private var label: String
    @State private var owner: String
    @State private var mode: ConnectionMode
    @State private var credential = ""
    @State private var error: String?
    @State private var signingIn = false
    @State private var signInStatus: String?
    init(integration: Integration, account: ConnectedAccount?) {
        self.integration = integration; self.account = account
        _label = State(initialValue: account?.label ?? "")
        _owner = State(initialValue: account?.billingScope ?? "")
        _mode = State(initialValue: account?.mode ?? (integration.status == .ready ? .live : .manual))
    }
    var body: some View {
        EditorFrame(title: account == nil ? "Add \(integration.name)" : "Edit \(integration.name)", saveLabel: account == nil ? "Add Account" : "Save Account", error: error, save: save) {
            Section {
                TextField("Account Label", text: $label, prompt: Text("Personal or Work"))
                if account == nil {
                    TextField("Billing Owner", text: $owner, prompt: Text(integration.id == "codex" ? "ChatGPT Plus, personal" : "Organization or billing account"))
                    if integration.status == .ready {
                        Picker("Connection", selection: $mode) { Text("Live Connection").tag(ConnectionMode.live); Text("Manual Records").tag(ConnectionMode.manual) }
                    }
                } else { LabeledContent("Billing Owner", value: owner.isEmpty ? "Unspecified" : owner) }
            } footer: { Text("Connect each billing owner once. Two keys for the same owner share one balance.") }
            if mode == .live && !integration.needsCredential {
                Section {
                    Label(integration.id == "codex" ? "Uses the Codex app on this Mac" : "Uses Claude Code on this Mac", systemImage: "terminal")
                    Text(integration.id == "codex"
                         ? "Unifai asks Codex for your ChatGPT plan, Codex usage windows and credits. Codex keeps the sign-in; Unifai stores no OpenAI password or token."
                         : "Unifai asks Claude Code which plan you are signed in to. Claude Code keeps the sign-in; Unifai never reads its token. Anthropic does not share subscription usage limits with other apps.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(SignIn.title(integration.id)) { startSignIn() }.disabled(signingIn)
                        if signingIn { ProgressView().controlSize(.small) }
                        if let signInStatus { Text(signInStatus).font(.caption).foregroundStyle(.secondary) }
                    }
                } footer: { Text(integration.id == "codex" ? "Already signed in to Codex? Skip this and add the account." : "Already signed in to Claude Code? Skip this and add the account.") }
            } else if mode == .live {
                Section {
                    SecureField(account == nil ? "Credential" : "Replace Credential", text: $credential, prompt: Text(account == nil ? (integration.id == "openai-api" ? "sk-admin-..." : "Paste a key") : "Leave blank to keep the saved key"))
                        .textContentType(.password)
                    Text(credentialHint).font(.caption).foregroundStyle(.secondary)
                } footer: { Text("Saved per account in macOS Keychain. No refresh occurs until you click Refresh. In a synthetic workspace, keys stay in memory and requests use fixtures.") }
            }
            Section { Text(integration.limitation).font(.callout).foregroundStyle(.secondary) }
        }
    }
    private func startSignIn() {
        signingIn = true; signInStatus = integration.id == "codex" ? "Finish in your browser" : nil; error = nil
        Task {
            do {
                try await SignIn.start(integration.id)
                signInStatus = integration.id == "codex" ? "Signed in" : "Finish in Terminal, then add the account"
            } catch { self.error = error.localizedDescription; signInStatus = nil }
            signingIn = false
        }
    }
    private var credentialHint: String {
        switch integration.id {
        case "openrouter": return "OpenRouter requires a management key. It has broad account authority; Unifai only sends GET /api/v1/credits."
        case "openai-api": return "Create an organization Admin key at platform.openai.com > Settings > Organization > Admin keys. It has broad access; Unifai only sends GET /v1/organization/costs."
        default: return "Unifai only sends GET /user/balance with the key you enter."
        }
    }
    private func save() {
        do {
            if let account { try store.updateAccount(account.id, label: label, credential: credential) }
            else { try store.addAccount(integrationID: integration.id, label: label, billingScope: owner, mode: mode, credential: credential) }
            credential = ""; dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct AccountPicker: View {
    @EnvironmentObject private var store: AppStore
    @Binding var selection: UUID?
    var body: some View {
        Picker("Account", selection: $selection) {
            Text("Unassigned").tag(nil as UUID?)
            ForEach(store.state.accounts) { Text("\(Catalogue.integration($0.integrationID)?.name ?? $0.integrationID) · \($0.label)").tag(Optional($0.id)) }
        }
    }
}

struct PaymentEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let record: PaymentRecord?
    @State private var account: UUID?
    @State private var name: String
    @State private var kind: PaymentKind
    @State private var amount: String
    @State private var currency: String
    @State private var paidAt: Date
    @State private var reference: String
    @State private var error: String?
    init(record: PaymentRecord?) {
        self.record = record
        _account = State(initialValue: record?.accountID)
        _name = State(initialValue: record?.description ?? "")
        _kind = State(initialValue: record?.kind ?? .topUp)
        _amount = State(initialValue: record.map { $0.money.amount > 0 ? $0.money.amount.description : "" } ?? "")
        _currency = State(initialValue: record?.money.currency ?? "USD")
        _paidAt = State(initialValue: record?.paidAt ?? .now)
        _reference = State(initialValue: record?.reference ?? "")
    }
    var body: some View {
        EditorFrame(title: "Confirmed Payment", saveLabel: "Save Payment", error: error, save: save) {
            Section {
                TextField("Description", text: $name, prompt: Text("Credit purchase or subscription"))
                AccountPicker(selection: $account)
                Picker("Payment Type", selection: $kind) { ForEach(PaymentKind.allCases) { Text($0.rawValue).tag($0) } }
                TextField("Amount", text: $amount, prompt: Text("100.00"))
                TextField("Currency", text: $currency, prompt: Text("USD or CNY"))
                DatePicker("Paid On", selection: $paidAt, in: ...Date.now, displayedComponents: .date)
                TextField("Receipt Reference", text: $reference, prompt: Text("Optional, used to detect duplicates"))
            } footer: { Text("Use a positive amount, including for refunds. Refunds reduce money paid. Enter a decimal point without thousands separators. Scheduled renewals belong in Subscriptions.") }
        }
    }
    private func save() {
        do {
            guard let value = Money.parseAmount(amount) else { throw ValidationError.message("Enter an amount such as 100.00, using a decimal point.") }
            let item = PaymentRecord(id: record?.id ?? UUID(), accountID: account, description: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind,
                                     money: Money(value, currency.trimmingCharacters(in: .whitespacesAndNewlines)), paidAt: paidAt, reference: reference.trimmingCharacters(in: .whitespacesAndNewlines))
            try store.savePayment(item); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct SubscriptionEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let schedule: SubscriptionSchedule?
    @State private var account: UUID?
    @State private var name: String
    @State private var amount: String
    @State private var currency: String
    @State private var cadence: BillingCadence
    @State private var renewal: Date
    @State private var error: String?
    init(schedule: SubscriptionSchedule?) {
        self.schedule = schedule
        _account = State(initialValue: schedule?.accountID)
        _name = State(initialValue: schedule?.name ?? "")
        _amount = State(initialValue: schedule?.price.amount.description ?? "")
        _currency = State(initialValue: schedule?.price.currency ?? "USD")
        _cadence = State(initialValue: schedule?.cadence ?? .monthly)
        _renewal = State(initialValue: schedule?.nextRenewal ?? .now)
    }
    var body: some View {
        EditorFrame(title: "Subscription Schedule", saveLabel: "Save Schedule", error: error, save: save) {
            Section {
                TextField("Subscription Name", text: $name, prompt: Text("Plan name"))
                AccountPicker(selection: $account)
                TextField("Expected Amount", text: $amount, prompt: Text("20.00"))
                TextField("Currency", text: $currency, prompt: Text("USD"))
                Picker("Cadence", selection: $cadence) { ForEach(BillingCadence.allCases) { Text($0.rawValue).tag($0) } }
                DatePicker("Next Expected Renewal", selection: $renewal, displayedComponents: .date)
            } footer: { Text("This records an expected charge. It does not change your provider plan or add past payments. Record each completed renewal separately and update its next date.") }
        }
    }
    private func save() {
        do {
            guard let value = Money.parseAmount(amount) else { throw ValidationError.message("Enter an expected amount such as 20.00.") }
            try store.saveSubscription(.init(id: schedule?.id ?? UUID(), accountID: account, name: name.trimmingCharacters(in: .whitespacesAndNewlines), price: Money(value, currency.trimmingCharacters(in: .whitespacesAndNewlines)), cadence: cadence, nextRenewal: renewal))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct RepositoryEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var slug = ""
    @State private var prereleases = false
    @State private var error: String?
    var body: some View {
        EditorFrame(title: "Follow Public Repository", saveLabel: "Follow Repository", error: error, save: save) {
            Section {
                TextField("Repository", text: $slug, prompt: Text("owner/repository"))
                Toggle("Include Prereleases", isOn: $prereleases)
            } footer: { Text("A local follow in Unifai. Your GitHub stars and watches are unchanged. Refresh after adding to retrieve the latest 50 releases. Private repositories and GitHub credentials are not supported.") }
        }
    }
    private func save() {
        do { try store.addRepository(slug, includePrereleases: prereleases); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

struct CoverageEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date = .now
    @State private var complete = false
    @State private var error: String?
    var body: some View {
        EditorFrame(title: "Payment History Coverage", saveLabel: "Save Coverage", error: error, save: save) {
            Section {
                DatePicker("Recorded Since", selection: $start, in: ...Date.now, displayedComponents: .date)
                Toggle("All Payments Since This Date Are Recorded", isOn: $complete)
            } footer: { Text("Only confirm completeness after checking your receipts for every account. The total covers this period. A current balance cannot establish lifetime spending.") }
        }.onAppear { start = store.state.coverageStart ?? .now; complete = store.state.historyCoverage?.completeForPeriod ?? false }
    }
    private func save() {
        do { try store.setCoverage(start: Calendar.current.startOfDay(for: start), complete: complete); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
