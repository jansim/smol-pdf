import SwiftUI

struct PasswordSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: PDFItem
    @State private var password = ""
    @State private var wrong = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.doc.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("“\(item.name)” is password protected")
                        .font(.headline)
                    Text("Enter the password to compress it. The compressed file keeps the same password.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            SecureField("Password", text: $password)
                .onSubmit(unlock)
            if wrong {
                Text("Incorrect password.").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Unlock", action: unlock)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func unlock() {
        if model.unlock(item, password: password) {
            dismiss()
        } else {
            wrong = true
        }
    }
}
