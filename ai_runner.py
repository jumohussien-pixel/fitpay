import os
import subprocess
from google import genai

client = genai.Client(api_key=os.getenv("GEMINI_API_KEY"))

def get_file_content(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()

def write_file_content(path, content):
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)

def run_flutter_analyze():
    result = subprocess.run(["flutter", "analyze"], capture_output=True, text=True)
    return result.returncode == 0, result.stdout

def push_to_github(commit_msg):
    subprocess.run(["git", "add", "."])
    subprocess.run(["git", "commit", "-m", commit_msg])
    subprocess.run(["git", "push"])
    print("🚀 تم الرفع إلى GitHub بنجاح!")

def start_workflow(target_file, prompt):
    print("⏳ جارٍ إرسال الطلب لـ Google AI Studio...")
    original_code = get_file_content(target_file)

    full_prompt = f"عدل الكود التالي بناءً على هذا الطلب: {prompt}\n\nرجع الكود المعدل فقط بدون أي شرح أو markdown.\n\n{original_code}"

    response = client.models.generate_content(
        model="gemini-2.0-flash-lite",
        contents=full_prompt,
    )

    new_code = response.text.replace("```dart", "").replace("```", "").strip()
    write_file_content(target_file, new_code)
    print("✅ تم تحديث الكود محلياً.")

    print("🔍 جارٍ فحص الكود (Flutter Analyze)...")
    success, log = run_flutter_analyze()

    attempts = 0
    while not success and attempts < 3:
        attempts += 1
        print(f"⚠️ ظهرت أخطاء، المحاولة رقم {attempts} للإصلاح تلقائياً...")
        fix_prompt = f"الكود التالي يحتوي على الأخطاء دي:\n{log}\n\nصلح الأخطاء ورجّع الكود كامل فقط بدون أي كلام إضافي:\n\n{get_file_content(target_file)}"

        fix_response = client.models.generate_content(
            model="gemini-2.0-flash-lite",
            contents=fix_prompt,
        )
        write_file_content(target_file, fix_response.text.replace("```dart", "").replace("```", "").strip())
        success, log = run_flutter_analyze()

    if success:
        print("🎉 الكود سليم 100%! جارٍ الرفع إلى GitHub...")
        push_to_github(f"Auto-fix: {prompt}")
    else:
        print("❌ لم يتمكن من حل الأخطاء بعد عدة محاولات. تفقد الـ Log:")
        print(log)

if __name__ == "__main__":
    file_path = "lib/main.dart"
    user_prompt = input("اكتب المشكلة أو التعديل المطلوب: ")
    start_workflow(file_path, user_prompt)
