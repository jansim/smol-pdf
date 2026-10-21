// Work spread over all cores, progress reporting and cancellation.

#include "Engine.hh"

#include <algorithm>
#include <condition_variable>
#include <cstdlib>
#include <deque>
#include <mutex>
#include <thread>

namespace smol {

namespace {

// How often the progress callback is called at most.
constexpr auto report_interval = std::chrono::milliseconds(100);
// Tasks are started while what all calls hold stays below this, but each call always gets one.
constexpr size_t memory_budget = size_t(1) << 30;

// The worker threads, one per core, shared by all smol_compress calls in the process.
class Workers {
  public:
    static Workers& shared() {
        // Never destroyed: the threads run until the process ends.
        static Workers* const workers = new Workers();
        return *workers;
    }

    size_t count() const { return count_; }

    void post(std::function<void()> work) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            queue_.push_back(std::move(work));
        }
        ready_.notify_one();
    }

    // Memory held by the tasks of all calls.
    std::atomic<size_t> memory{0};

  private:
    Workers() {
        long count = long(std::thread::hardware_concurrency());
        if (char const* env = std::getenv("SMOL_THREADS")) count = std::atol(env);
        count_ = size_t(std::clamp(count, 1L, 64L));
        for (size_t i = 0; i < count_; ++i) std::thread([this] { loop(); }).detach();
    }

    void loop() {
        for (;;) {
            std::function<void()> work;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                ready_.wait(lock, [&] { return !queue_.empty(); });
                work = std::move(queue_.front());
                queue_.pop_front();
            }
            work();
        }
    }

    size_t count_ = 1;
    std::mutex mutex_;
    std::condition_variable ready_;
    std::deque<std::function<void()>> queue_;
};

// Tasks that have run, waiting to be applied. Shared with the workers, so it outlives the call.
struct Finished {
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<std::pair<Task*, bool>> tasks; // with whether run() threw
};

} // namespace

void Progress::report(bool force) {
    check();
    if (!callback_) return;
    auto now = std::chrono::steady_clock::now();
    if (!force && now - last_ < report_interval) return;
    last_ = now;
    double fraction = total_ ? double(done_.load(std::memory_order_relaxed)) / double(total_) : 0;
    reported_ = std::max(reported_, std::min(fraction, 1.0));
    if (callback_(context_, reported_)) {
        stop();
        throw Cancelled();
    }
}

void runTasks(std::function<std::unique_ptr<Task>()> const& next, Progress& progress) {
    Workers& workers = Workers::shared();
    auto finished = std::make_shared<Finished>();
    std::vector<std::unique_ptr<Task>> running;

    // Takes a finished task out of `running`; with `wait`, blocks until there is one.
    auto take = [&](bool wait) -> std::pair<std::unique_ptr<Task>, bool> {
        std::unique_lock<std::mutex> lock(finished->mutex);
        auto any = [&] { return !finished->tasks.empty(); };
        if (wait) finished->changed.wait(lock, any);
        else if (!finished->changed.wait_for(lock, report_interval, any)) return {nullptr, false};
        auto [raw, failed] = finished->tasks.back();
        finished->tasks.pop_back();
        lock.unlock();
        auto it = std::find_if(running.begin(), running.end(), [&](auto const& t) { return t.get() == raw; });
        std::unique_ptr<Task> task = std::move(*it);
        running.erase(it);
        workers.memory -= task->memory();
        return {std::move(task), failed};
    };

    // Whatever happens, wait for the tasks that are still running: they use `progress`.
    struct Drain {
        std::vector<std::unique_ptr<Task>>& running;
        Progress& progress;
        std::function<std::pair<std::unique_ptr<Task>, bool>(bool)> take;
        ~Drain() {
            if (running.empty()) return;
            progress.stop();
            while (!running.empty()) take(true);
        }
    } drain{running, progress, take};

    std::unique_ptr<Task> waiting; // made, but not started for lack of memory
    bool more = true;
    for (;;) {
        // Keep every worker busy, plus one task queued so none waits for the next to be made.
        while (running.size() < workers.count() + 1) {
            if (!waiting && more) {
                waiting = next();
                more = waiting != nullptr;
                progress.report();
            }
            if (!waiting) break;
            size_t need = waiting->memory();
            if (!running.empty() && workers.memory.load() + need > memory_budget) break;
            // Allocate everything before the hand-off, so that nothing can fail half-way: a task
            // in `running` that never reaches a worker would be waited for forever.
            Task* raw = waiting.get();
            std::function<void()> work = [raw, finished, &progress] {
                bool failed = false;
                try {
                    raw->run(progress);
                } catch (...) {
                    failed = true;
                }
                std::lock_guard<std::mutex> lock(finished->mutex);
                finished->tasks.emplace_back(raw, failed); // never allocates: reserved below
                finished->changed.notify_one();
            };
            running.reserve(running.size() + 1);
            {
                std::lock_guard<std::mutex> lock(finished->mutex);
                finished->tasks.reserve(running.size() + 1);
            }
            running.push_back(std::move(waiting));
            workers.memory += need;
            try {
                workers.post(std::move(work));
            } catch (...) {
                workers.memory -= need;
                waiting = std::move(running.back());
                running.pop_back();
                throw;
            }
        }
        if (running.empty()) break;
        auto [task, failed] = take(false);
        if (task) task->apply(failed);
        progress.report();
    }
}

} // namespace smol
