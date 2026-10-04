# 生成しながらの再生と停止

[API](API.md) · [PCM再生の補助クラス](../Examples/Shared/PCMPlayer.swift)

文章を文単位で合成し、デコーダが出力するPCMチャンクを順に受け取れます。全文の完成を待ってから再生する必要はありません。任意長の1文を先頭から無制限に生成する方式ではなく、長い一文では最初のチャンクまでの時間も伸びます。


**iPhone/MacのGUIサンプルは全文合成後のWAV再生です。** `splitSentences: false` と `onChunk` 省略で、句読点分割や擬似ストリーミング再生を行いません。ここにあるチャンク再生は、必要なアプリに任意で組み込む別の例です。全文一回の合成とPCM通知の選択は独立しています。[全文モードのAPI](API.md#文章整形と長文)を参照してください。
## アプリへの組み込み例

以下のコードと [PCMPlayer.swift](../Examples/Shared/PCMPlayer.swift) を自分のアプリtargetに追加します。PCMPlayerはサンプルのクラスで、`import IrodoriTTS` だけでは使えません。モデル検証・保存と参照音声の許可確認は呼び出し前に行ってください。

```swift
import Foundation
import Combine
import IrodoriTTS

@MainActor
final class SpeechController: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    private let engine = IrodoriEngine()
    private let player = PCMPlayer()
    private var task: Task<Void, Never>?
    private var requestID = UUID()

    func speak(_ text: String, models: URL, reference: URL?) {
        guard !busy else { return }
        player.stop()
        busy = true
        let id = UUID()
        requestID = id
        task = Task { [self] in
            defer { busy = false; task = nil }
            do {
                try await engine.prepare(modelDirectory: models)
                try Task.checkCancellation()
                try await engine.registerReference(reference)
                try Task.checkCancellation()
                let result = try await engine.synthesize(text) { [weak self] chunk in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.requestID == id else { return }
                        do { try self.player.append(chunk.pcm16) }
                        catch {
                            self.stop()
                            self.status = error.localizedDescription
                        }
                    }
                }
                try Task.checkCancellation()
                status = String(format: "生成完了 / RTF %.3f", result.rtf)
            } catch is CancellationError {
                if requestID == id { stop() }
            } catch {
                if requestID == id {
                    stop()
                    status = error.localizedDescription
                }
            }
        }
    }

    func stop() {
        requestID = UUID() // MainActorに到着待ちの古いチャンクも破棄する
        task?.cancel()
        player.stop()
        status = "停止しました。"
    }

    func close() async {
        stop()
        await task?.value
        await engine.release()
    }
}
```

busyは合成処理の状態であり、スピーカーの再生完了を表しません。例ではbusy中の新規発話を受け付けず、次の発話を始めると前の再生を止めます。再生完了に合わせて発話をつなぐ製品UIでは、プレイヤー側に完了通知と順序管理を追加してください。バックグラウンド再生や着信・出力デバイス変更の処理まで網羅する例ではありません。

## 停止の範囲

合成Taskをキャンセルすると、以後のチャンクは破棄し、次の文へ進みません。実行中のCore ML予測は終了を待ちます。モデル準備・参照登録にも即時停止APIはありません。画面の「停止」はプレイヤーを先に止め、合成終了後に次の操作を許可する構成にします。

キャンセル・エラー前に一部のPCMが通知される場合があります。途中まで聞こえた文章全体を自動で再試行すると同じ発話を繰り返すため、再試行はアプリ側で扱ってください。識別IDは、停止前にMainActorへ送られたチャンクが後から鳴ることを防ぎます。

## LLMの出力をつなぐとき

1. LLMから届くテキストを蓄積し、句点等で確定した一文を取り出します。トークン1つごとにTTSへ渡さないでください。
2. 1つのengineへ、確定した順に `await engine.synthesize(sentence, onChunk: ...)` を渡します。
3. 再生バッファは文ごとに停止・作り直しせず継続します。上の単発発話用speakをそのままLLMの文ごとに呼ぶ設計にはしないでください。
4. ユーザーが割り込んだら、LLM側の生成、TTSの待ち行列、合成Task、プレイヤーをそれぞれ止めます。

文字装飾・URLはSDKの通常モードで整形します。自分のアプリで編集する場合も、画面表示用と読み上げ用の文章を別に保持すると、URLを画面には残しつつ発話だけ整えられます。

ASRやLLMの処理はアプリ側で実装します。RTFから会話全体の待ち時間を推定せず、音声入力終了→最初の実再生をアプリで計測してください。

## 長文とメモリ

SDKはチャンク通知と同時に完成PCMも保持します。無期限の音声を一定メモリで生成するAPIではありません。チャットでは確定した文ごとに生成し、保存不要なSynthesisResultを保持し続けないようにします。1つのengineの再利用はモデルの重複保持も避けられます。

AudioSeal透かしは標準で有効です。RTFと最初のPCM時間に処理を含めます。PCM通知では0.5秒分の音声を先読みします。[透かしの処理と制約](WATERMARK.md)を参照してください。
