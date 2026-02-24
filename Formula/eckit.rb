class Eckit < Formula
  desc "ECMWF cross-platform c++ toolkit"
  homepage "https://github.com/ecmwf/eckit"
  url "https://github.com/ecmwf/eckit/archive/refs/tags/1.29.3.tar.gz"
  sha256 "5afb6ac5bd95d68b7b0fdf42bdfe21370515b8e9ef7b3db91a89e021aa9133f2"
  # url "https://github.com/ecmwf/eckit/archive/refs/tags/1.24.4.tar.gz"
  # sha256 "b6129eb4f7b8532aa6905033e4cf7d09aadc8547c225780fea3db196e34e4671"
  # url "https://github.com/ecmwf/eckit/archive/refs/tags/2.0.0.tar.gz"
  # sha256 "172e6e1226b61db44d9095e70d45612eb0887ce82bc1077d4f02200355334749"
  
  license "Apache-2.0"

  livecheck do
    url "https://github.com/ecmwf/eckit/tags"
    regex(/^v?(\d(?:\.\d+)+)$/i)
  end

  # bottle do
  #   root_url "https://get-test.ecmwf.int/repository/homebrew"
  #   sha256 cellar: :any,                 arm64_ventura: "7e545a6c6f8c191f5bbd4257a9fafb94d726551545bb047c226fad4b7907598b"
  #   sha256 cellar: :any,                 ventura:       "ffd407eb71e59778273b606849a313eddb97829f191459bd38c61afa7d3452ee"
  #   sha256 cellar: :any_skip_relocation, x86_64_linux:  "0f90e46adb26221374b0fd8009d030996a513025b977b217fc913f4c32e7c701"
  # end

  depends_on "cmake" => [:build, :test]
  depends_on "ecbuild" => [:build, :test]
  depends_on "lapack"
  depends_on "lz4"
  depends_on "openblas"
  depends_on "eigen" => :recommended
  uses_from_macos "bzip2"
  uses_from_macos "ncurses"
  uses_from_macos "openssl"

  patch :DATA

  def install
    mkdir "build" do
      system "ecbuild", "..", "-DENABLE_MPI=OFF", *std_cmake_args
      system "make", "install"
    end

    shim_references = [
      lib/"pkgconfig/eckit_mpi.pc",
      lib/"pkgconfig/eckit_cmd.pc",
      lib/"pkgconfig/eckit_test_value_custom_params.pc",
      lib/"pkgconfig/eckit_option.pc",
      lib/"pkgconfig/eckit_maths.pc",
      lib/"pkgconfig/eckit_web.pc",
      lib/"pkgconfig/eckit_sql.pc",
      lib/"pkgconfig/eckit.pc",
      lib/"pkgconfig/eckit_linalg.pc",
      lib/"pkgconfig/eckit_geometry.pc",
      lib/"pkgconfig/eckit_distributed.pc",
      include/"eckit/eckit_ecbuild_config.h",
    ]
    inreplace shim_references, Superenv.shims_path/ENV.cxx, ENV.cxx
    inreplace shim_references, Superenv.shims_path/ENV.cc, ENV.cc
  end

  test do
    # write a CMakeLists.txt for building the test
    (testpath/"src/CMakeLists.txt").write <<~EOS
      cmake_minimum_required(VERSION 3.11 FATAL_ERROR)
      find_package(ecbuild REQUIRED)
      project(test_eckit VERSION 0.1.0 LANGUAGES CXX)
      set(CMAKE_CXX_STANDARD 11)
      set(CMAKE_CXX_STANDARD_REQUIRED ON)
      ecbuild_find_package( NAME eckit REQUIRED )
      ecbuild_add_executable(
        TARGET      eckit-test
        SOURCES     test.cc
        LIBS        eckit_maths eckit )
    EOS

    # source code for the test
    (testpath/"src/test.cc").write <<~EOS
      #include <cassert>
      #include <iomanip>
      #include "eckit/testing/Test.h"
      #include "eckit/types/FloatCompare.h"
      #include "eckit/types/Hour.h"
      #include "eckit/maths/Matrix.h"
      #include "eckit/container/DenseMap.h"

      using namespace std;
      using namespace eckit;
      using namespace eckit::testing;

      int main() {

        // test time utilities
        assert(Hour(1.0/60.0) == Hour("0:01"));

        // test containers
        DenseMap<std::string, int> dm;
        dm.insert("two", 2);
        dm.insert("four", 4);
        dm.insert("nine", 9);
        dm.sort();
        assert(dm.get("two") == 2);
        assert(dm.get("nine") == 9);
        assert(dm.get("four") == 4);

        // test matrix functions
        constexpr double tolerance = 1.e-8;
        using eckit::types::is_approximately_equal;
        using Matrix = eckit::maths::Matrix<double>;
        Matrix m{{9., 6., 2., 0., 3.},
                 {3., 6., 8., 10., 12.},
                 {4., 8., 2., 6., 9.},
                 {1., 5., 5., 3., 2.},
                 {1., 3., 6., 8., 10}};
        assert(is_approximately_equal(m.determinant(), 1124., tolerance));
        return 0;
      }
    EOS

    # build using ecbuild to ensure correct compilation flags
    # also set build type to Debug so as to activate assert()
    system "ecbuild", "./src", "-DCMAKE_BUILD_TYPE=Debug"
    system "make"
    system "file", "./bin/eckit-test"
    system "./bin/eckit-test"
  end
end

__END__
--- src/eckit/serialisation/Stream.cc
+++ src/eckit/serialisation/Stream.cc
@@ -215,6 +215,13 @@
     }
 
     if (need != t) {
+        // Allow cross-platform off_t / size_t integer tag mismatches
+        if ((need == tag_long_long && t == tag_long) ||
+            (need == tag_long && t == tag_long_long) ||
+            (need == tag_unsigned_long_long && t == tag_unsigned_long) ||
+            (need == tag_unsigned_long && t == tag_unsigned_long_long)) {
+            return t; 
+        }
         badTag(need, t);
     }
 
@@ -499,9 +506,14 @@
         uint32_t u;
         int32_t s;
     } u;
-    readTag(tag_long);
-    u.u = getLong();
-    x   = u.s;
+    if (readTag(tag_long) == tag_long_long) {
+        uint64_t u1 = getLong();
+        uint64_t u2 = getLong();
+        x = static_cast<long>((u1 << 32) | u2);
+    } else {
+        u.u = getLong();
+        x   = u.s;
+    }
     T("r long", x);
     return *this;
 }
@@ -509,8 +521,13 @@
 Stream& Stream::operator>>(unsigned long& x) {
-    readTag(tag_unsigned_long);
-    x = getLong();
+    if (readTag(tag_unsigned_long) == tag_unsigned_long_long) {
+        unsigned long long u1 = getLong();
+        unsigned long long u2 = getLong();
+        x = static_cast<unsigned long>((u1 << 32) | u2);
+    } else {
+        x = getLong();
+    }
     T("r unsigned long", x);
     return *this;
 }
@@ -520,12 +537,16 @@
         uint64_t u;
         int64_t s;
     } u;
-    readTag(tag_long_long);
-    uint64_t u1 = getLong();
-    ;
-    uint64_t u2 = getLong();
-    u.u         = (u1 << 32) | u2;
-    x           = u.s;
+    if (readTag(tag_long_long) == tag_long) {
+        u.u = getLong();    // Reads 32 bits
+        x = static_cast<long long>(u.s); // Safely sign-extends to 64-bit
+    } else {
+        uint64_t u1 = getLong();
+        uint64_t u2 = getLong();
+        u.u         = (u1 << 32) | u2;
+        x           = u.s;
+    }
     T("r long long", x);
     return *this;
 }
@@ -536,10 +557,14 @@
 Stream& Stream::operator>>(unsigned long long& x) {
-    readTag(tag_unsigned_long_long);
-    unsigned long long u1 = getLong();
-    ;
-    unsigned long long u2 = getLong();
-    x                     = (u1 << 32) | u2;
+    if (readTag(tag_unsigned_long_long) == tag_unsigned_long) {
+        x = static_cast<unsigned long long>(getLong());
+    } else {
+        unsigned long long u1 = getLong();
+        unsigned long long u2 = getLong();
+        x                     = (u1 << 32) | u2;
+    }
     T("r unsigned long long", x);
     return *this;
 }
