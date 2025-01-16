import threading
import time
from google.colab import runtime

#ランタイム切断を管理する関数
def cut_connect(ランタイムの切断時間指定):
    if ランタイムの切断時間指定 == -1:
        print("無制限モードが選択されました。ランタイムは手動で切断してください。")
        return  # 無制限の場合は処理を終了
    try:
        print(f"ランタイムを {ランタイムの切断時間指定} 秒後に切断します...")
        time.sleep(ランタイムの切断時間指定)
        runtime.unassign()
        print(f"ランタイムを切断しました。")
    except ValueError:
        print("無効な秒数が入力されました。正しい数値を入力してください。")
