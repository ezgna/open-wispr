## macOS app bundle と署名
- `OpenWispr.app` はローカルのビルド成果物で、Git 管理対象ではない。
- app bundle や実行ファイルを差し替える場合、`codesign --sign -` などの ad hoc 署名で済ませない。
- 有効な署名 identity がない場合は、署名済み bundle の差し替えや再起動を行わず、ソース修正とテスト確認までに留める。
- 署名状態を確認するときは `codesign -dv --verbose=4 OpenWispr.app` で `Signature=adhoc` になっていないことを確認する。
