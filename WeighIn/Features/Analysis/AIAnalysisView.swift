import SwiftUI
import UniformTypeIdentifiers

struct AIAnalysisView: View {
    private let useCase: any AnalysisUseCase
    @State private var showJSONExporter = false

    init(useCase: any AnalysisUseCase) {
        self.useCase = useCase
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("AI Analysis")
                    .font(.largeTitle.bold())
                    .foregroundStyle(AppTheme.textPrimary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Coming Soon")
                        .font(.headline)
                        .foregroundStyle(AppTheme.textPrimary)

                    Text("Deeper pattern analysis from your weight trajectory and reflections will appear here.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.textSecondary)

                    Text("Tip: Export JSON here (or from Settings) and upload it to your favorite AI chatbot for deep analysis of trends, notes, and correlations.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)

                    Text("JSON export includes your logs, linked notes, settings, and profile info.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.surface)
                )

                Button {
                    showJSONExporter = true
                } label: {
                    Label("Export JSON", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(AppTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(16)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .fileExporter(
            isPresented: $showJSONExporter,
            document: AIJSONExportDocument(data: useCase.exportJSON()),
            contentType: .json,
            defaultFilename: "weighin-export"
        ) { result in
            if case let .failure(error) = result {
                useCase.lastErrorMessage = "Unable to export JSON: \(error.localizedDescription)"
            }
        }
    }
}

private struct AIJSONExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
