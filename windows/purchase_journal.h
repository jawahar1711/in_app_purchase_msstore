#pragma once

#include <Windows.h>
#include <winrt/base.h>
#include <filesystem>
#include <stdexcept>
#include <string>

namespace in_app_purchase_msstore::journal {
inline std::string Read(const std::filesystem::path& path) {
  const HANDLE raw = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                               nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (raw == INVALID_HANDLE_VALUE) {
    const auto error = GetLastError();
    if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) return "[]";
    winrt::throw_last_error();
  }
  winrt::handle file(raw);
  LARGE_INTEGER size;
  winrt::check_bool(GetFileSizeEx(file.get(), &size));
  if (size.QuadPart < 0 || size.QuadPart > 16 * 1024 * 1024)
    throw std::runtime_error("Purchase journal size is invalid.");
  std::string text(static_cast<size_t>(size.QuadPart), '\0');
  DWORD read = 0;
  winrt::check_bool(ReadFile(file.get(), text.data(), static_cast<DWORD>(text.size()), &read, nullptr));
  if (read != text.size()) throw std::runtime_error("Incomplete purchase journal read.");
  return text;
}

inline void Write(const std::filesystem::path& path, const std::string& text) {
  if (text.size() > 16 * 1024 * 1024) throw std::runtime_error("Purchase journal is too large.");
  std::filesystem::create_directories(path.parent_path());
  auto temporary = path;
  temporary += L".tmp";
  {
    const HANDLE raw = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr,
                                 CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (raw == INVALID_HANDLE_VALUE) winrt::throw_last_error();
    winrt::handle file(raw);
    DWORD written = 0;
    winrt::check_bool(WriteFile(file.get(), text.data(), static_cast<DWORD>(text.size()), &written, nullptr));
    if (written != text.size()) throw std::runtime_error("Incomplete purchase journal write.");
    winrt::check_bool(FlushFileBuffers(file.get()));
  }
  winrt::check_bool(MoveFileExW(temporary.c_str(), path.c_str(),
                              MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH));
}
}  // namespace in_app_purchase_msstore::journal
