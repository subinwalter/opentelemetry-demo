// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

using Accounting;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using OpenFeature;
using OpenFeature.Contrib.Providers.Flagd;

Console.WriteLine("Accounting service started");

Environment.GetEnvironmentVariables()
    .FilterRelevant()
    .OutputInOrder();

var host = Host.CreateDefaultBuilder(args)
    .ConfigureServices(services =>
    {
        services.AddOpenFeature(builder =>
        {
            builder.AddProvider(_ => new FlagdProvider());
        });
        services.AddSingleton<Consumer>();
    })
    .Build();

var consumer = host.Services.GetRequiredService<Consumer>();
consumer.StartListening();

host.Run();
