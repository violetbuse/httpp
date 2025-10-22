import express from "express";

const app = express();

app.head("/", async (_, res) => {
    res.status(200).end();
});

app.get("/", async (_, res) => {
    res.status(200).send("hello world");
});

app.get("/json", async (_, res) => {
    res.status(200).send(JSON.stringify({ message: "hello world" }));
});

app.get("/stream", async (_, res) => {
    res.status(200);
    res.setHeader("Connection", "keep-alive");
    res.flushHeaders();

    let counter = 0;
    const interval = setInterval(() => {
        if (counter >= 10) {
            clearInterval(interval);
            res.write("done");
            res.end();
            return;
        }

        res.write(counter.toString() + "\n");
        counter++;
    }, 200);

    res.on("close", () => {
        clearInterval(interval);
        res.end();
    });
});

app.get("/stream/json", async (_, res) => {
    res.status(200);
    res.setHeader("Connection", "keep-alive");
    res.flushHeaders();

    let counter = 0;
    const interval = setInterval(() => {
        if (counter >= 10) {
            clearInterval(interval);
            res.write(JSON.stringify({ done: true }) + "\n");
            res.end();
            return;
        }

        res.write(JSON.stringify({ counter }) + "\n");
        counter++;
    }, 200);

    res.on("close", () => {
        clearInterval(interval);
        res.end();
    });
});

app.get("/sse", async (_, res) => {
    res.status(200);
    res.setHeader("Connection", "keep-alive");
    res.flushHeaders();

    let counter = 0;
    const interval = setInterval(() => {
        if (counter >= 10) {
            clearInterval(interval);
            res.end();
            return;
        }

        res.write(`data: ${counter.toString()}\n\n`);
        counter++;
    }, 200);

    res.on("close", () => {
        clearInterval(interval);
        res.end();
    });
});

app.get("/sse/with-event-type", async (_, res) => {
    res.status(200);
    res.setHeader("Connection", "keep-alive");
    res.flushHeaders();

    let counter = 0;
    const interval = setInterval(() => {
        if (counter >= 10) {
            clearInterval(interval);
            res.end();
            return;
        }

        res.write(`event: counter-event\ndata: ${counter.toString()}\n\n`);
        counter++;
    }, 200);

    res.on("close", () => {
        clearInterval(interval);
        res.end();
    });
});

app.get("/sse/with-multiline-data", async (_, res) => {
    res.status(200);
    res.setHeader("Connection", "keep-alive");
    res.flushHeaders();

    let counter = 0;
    const interval = setInterval(() => {
        if (counter >= 10) {
            clearInterval(interval);
            res.end();
            return;
        }

        res.write(
            `event: counter-event\ndata: ${counter.toString()}\ndata: line_1\ndata: line_2\n\n`,
        );
        counter++;
    }, 200);

    res.on("close", () => {
        clearInterval(interval);
        res.end();
    });
});

app.get("/sse/with-mixture", async (_, res) => {
    res.status(200);
    res.setHeader("Connection", "keep-alive");
    res.flushHeaders();

    res.write(": a silly lil comment\n\n");

    res.write(":comment-1\n:comment-2\n\n");

    res.write(`event: event-1\ndata: 0\n\n`);
    res.write(
        `data: line one of data\ndata: line two of data\ndata: line three of data\n\n`,
    );
    res.write(`event: event-3\n: comment-1\ndata: hello\ndata: world\n\n`);
    res.write(`event: event-4\nid: evt-id\ndata:hewwo`);
    res.write(`\ndata:  world\n\n`);

    res.end();
});

app.listen(1773);
